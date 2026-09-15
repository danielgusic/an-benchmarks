use std::{
    ptr,
    sync::{
        Arc,
        atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering},
    },
    thread::{self, JoinHandle},
    time::Duration,
};

use anyhow::Result;
use rand::{Rng, SeedableRng};
use rand_chacha::ChaCha8Rng;
use wasmtime::{AsContext, Memory, Store};

#[derive(Clone, Debug)]
pub(crate) struct FaultConfig {
    pub(crate) targets: Vec<FaultTarget>,
    pub(crate) seed: u64,
    pub(crate) period: Duration,
    pub(crate) max_flips: Option<u64>,
}

impl FaultConfig {
    pub(crate) fn new(
        targets: Vec<FaultTarget>,
        seed: u64,
        period: Duration,
        max_flips: Option<u64>,
    ) -> Self {
        Self {
            targets,
            seed,
            period,
            max_flips,
        }
    }

    pub(crate) fn target_list(&self) -> String {
        self.targets
            .iter()
            .map(|target| target.name())
            .collect::<Vec<_>>()
            .join(",")
    }

    pub(crate) fn uses_encoded_shadow(&self) -> bool {
        self.targets.contains(&FaultTarget::EncodedShadow)
    }

    pub(crate) fn can_leave_memory_mismatch(&self) -> bool {
        self.targets.contains(&FaultTarget::LinearMemory)
            || self.targets.contains(&FaultTarget::EncodedShadow)
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum FaultTarget {
    LinearMemory,
    EncodedShadow,
    GuestStack,
}

impl FaultTarget {
    fn name(self) -> &'static str {
        match self {
            FaultTarget::LinearMemory => "memory",
            FaultTarget::EncodedShadow => "shadow",
            FaultTarget::GuestStack => "stack",
        }
    }
}

pub(crate) struct FaultRuntime {
    memory: FaultRegion,
    shadow: FaultRegion,
    stack: FaultRegion,
    stop: AtomicBool,
    flips: AtomicU64,
}

impl FaultRuntime {
    pub(crate) fn new() -> Self {
        Self {
            memory: FaultRegion::new(),
            shadow: FaultRegion::new(),
            stack: FaultRegion::new(),
            stop: AtomicBool::new(false),
            flips: AtomicU64::new(0),
        }
    }

    fn region(&self, target: FaultTarget) -> &FaultRegion {
        match target {
            FaultTarget::LinearMemory => &self.memory,
            FaultTarget::EncodedShadow => &self.shadow,
            FaultTarget::GuestStack => &self.stack,
        }
    }

    pub(crate) fn clear_all(&self) {
        self.memory.clear();
        self.shadow.clear();
        self.stack.clear();
    }

    pub(crate) fn clear_stack(&self) {
        self.stack.clear();
    }

    pub(crate) fn request_stop(&self) {
        self.stop.store(true, Ordering::SeqCst);
    }
}

struct FaultRegion {
    epoch: AtomicUsize,
    base: AtomicUsize,
    len: AtomicUsize,
}

impl FaultRegion {
    fn new() -> Self {
        Self {
            epoch: AtomicUsize::new(0),
            base: AtomicUsize::new(0),
            len: AtomicUsize::new(0),
        }
    }

    fn update(&self, base: *mut u8, len: usize) {
        self.publish(base as usize, len);
    }

    fn clear(&self) {
        self.publish(0, 0);
    }

    fn snapshot(&self) -> Option<(usize, usize)> {
        let start = self.epoch.load(Ordering::SeqCst);
        if start % 2 != 0 {
            return None;
        }
        let base = self.base.load(Ordering::SeqCst);
        let len = self.len.load(Ordering::SeqCst);
        let end = self.epoch.load(Ordering::SeqCst);
        if start != end {
            return None;
        }
        if base == 0 || len == 0 {
            None
        } else {
            Some((base, len))
        }
    }

    fn publish(&self, base: usize, len: usize) {
        self.epoch.fetch_add(1, Ordering::SeqCst);
        self.base.store(base, Ordering::SeqCst);
        self.len.store(len, Ordering::SeqCst);
        self.epoch.fetch_add(1, Ordering::SeqCst);
    }
}

#[derive(Default)]
pub(crate) struct FaultStats {
    pub(crate) flips: u64,
    pub(crate) skipped: u64,
}

pub(crate) fn parse_fault_targets(raw: &str) -> Result<Vec<FaultTarget>> {
    let mut targets = Vec::new();
    for item in raw.split(',') {
        let item = item.trim().to_ascii_lowercase();
        match item.as_str() {
            "all" => {
                push_fault_target(&mut targets, FaultTarget::LinearMemory);
                push_fault_target(&mut targets, FaultTarget::EncodedShadow);
                push_fault_target(&mut targets, FaultTarget::GuestStack);
            }
            "mem" | "memory" | "linear" | "linear-memory" => {
                push_fault_target(&mut targets, FaultTarget::LinearMemory);
            }
            "shadow" | "encoded-shadow" | "an-shadow" => {
                push_fault_target(&mut targets, FaultTarget::EncodedShadow);
            }
            "stack" | "guest-stack" | "wasm-stack" => {
                push_fault_target(&mut targets, FaultTarget::GuestStack);
            }
            "" => {}
            other => {
                return Err(anyhow::anyhow!(
                    "unknown fault target {other:?}; use memory, shadow, stack, or all"
                ));
            }
        }
    }
    if targets.is_empty() {
        return Err(anyhow::anyhow!("--fault needs at least one target"));
    }
    Ok(targets)
}

fn push_fault_target(targets: &mut Vec<FaultTarget>, target: FaultTarget) {
    if !targets.contains(&target) {
        targets.push(target);
    }
}

pub(crate) fn parse_u64_arg(flag: &str, raw: String) -> Result<u64> {
    if let Some(hex) = raw.strip_prefix("0x").or_else(|| raw.strip_prefix("0X")) {
        u64::from_str_radix(hex, 16)
            .map_err(|e| anyhow::anyhow!("{flag} has invalid hex value {raw:?}: {e}"))
    } else {
        raw.parse::<u64>()
            .map_err(|e| anyhow::anyhow!("{flag} has invalid value {raw:?}: {e}"))
    }
}

pub(crate) fn refresh_initial_fault_regions<T: 'static>(
    store: &mut Store<T>,
    memory: Memory,
    faults: &FaultRuntime,
) {
    refresh_linear_fault_region(store.as_context(), memory, faults);
    if let Some(shadow) = memory.an_shadow_data_mut_for_test(&mut *store) {
        faults.shadow.update(shadow.as_mut_ptr(), shadow.len());
    } else {
        faults.shadow.clear();
    }
    if let Some((base, len)) = store.wasm_stack_raw_parts_for_test() {
        faults.stack.update(base, len);
    } else {
        faults.stack.clear();
    }
}

pub(crate) fn refresh_linear_fault_region<T: 'static>(
    store: wasmtime::StoreContext<'_, T>,
    memory: Memory,
    faults: &FaultRuntime,
) {
    faults
        .memory
        .update(memory.data_ptr(&store), memory.data_size(&store));
}

pub(crate) fn refresh_stack_fault_region<T: 'static>(
    store: wasmtime::StoreContext<'_, T>,
    faults: &FaultRuntime,
) {
    if let Some((base, len)) = store.wasm_stack_raw_parts_for_test() {
        faults.stack.update(base, len);
    } else {
        faults.stack.clear();
    }
}

pub(crate) fn start_fault_injector(
    config: FaultConfig,
    runtime: Arc<FaultRuntime>,
) -> JoinHandle<FaultStats> {
    thread::spawn(move || {
        let mut rng = ChaCha8Rng::seed_from_u64(config.seed);
        let mut stats = FaultStats::default();

        loop {
            if runtime.stop.load(Ordering::SeqCst) {
                break;
            }
            if config.max_flips.is_some_and(|max| stats.flips >= max) {
                runtime.request_stop();
                break;
            }

            let mut available = Vec::with_capacity(config.targets.len());
            for target in &config.targets {
                if let Some((base, len)) = runtime.region(*target).snapshot() {
                    available.push((*target, base, len));
                }
            }

            if available.is_empty() {
                stats.skipped += 1;
            } else {
                let (_, base, len) = available[rng.gen_range(0..available.len())];
                let ptr = base.wrapping_add(rng.gen_range(0..len)) as *mut u8;
                let bit = 1u8 << rng.gen_range(0..8);
                unsafe {
                    let old = ptr::read_volatile(ptr);
                    ptr::write_volatile(ptr, old ^ bit);
                }
                stats.flips += 1;
                runtime.flips.store(stats.flips, Ordering::SeqCst);
            }

            thread::sleep(config.period);
        }

        stats
    })
}
