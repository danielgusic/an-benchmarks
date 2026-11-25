use anyhow::{Result, bail};
use clap::ValueEnum;

#[derive(Clone, Copy, Debug, PartialEq, Eq, ValueEnum)]
pub enum Region {
    Memory,
    Shadow,
    Stack,
    Code,
    Runtime,
}

impl Region {
    pub fn name(self) -> &'static str {
        match self {
            Region::Memory => "memory",
            Region::Shadow => "shadow",
            Region::Stack => "stack",
            Region::Code => "code",
            Region::Runtime => "runtime",
        }
    }
}

#[derive(Clone, Copy, Debug)]
pub struct Span {
    pub start: usize,
    pub len: usize,
}

impl Span {
    pub fn new(start: usize, len: usize) -> Self {
        Self { start, len }
    }

    pub fn end(&self) -> usize {
        self.start + self.len
    }

    pub fn contains(&self, addr: usize) -> bool {
        (self.start..self.end()).contains(&addr)
    }
}

pub fn subtract(spans: &[Span], holes: &[Span]) -> Vec<Span> {
    let mut out = spans.to_vec();
    for hole in holes.iter().filter(|h| h.len > 0) {
        out = out
            .into_iter()
            .flat_map(|s| {
                let mut parts = Vec::with_capacity(2);
                if hole.end() <= s.start || hole.start >= s.end() {
                    parts.push(s);
                } else {
                    if hole.start > s.start {
                        parts.push(Span::new(s.start, hole.start - s.start));
                    }
                    if hole.end() < s.end() {
                        parts.push(Span::new(hole.end(), s.end() - hole.end()));
                    }
                }
                parts
            })
            .collect();
    }
    out
}

#[cfg(target_os = "linux")]
pub fn writable_mappings() -> Result<Vec<Span>> {
    let maps = std::fs::read_to_string("/proc/self/maps")?;
    let mut out = Vec::new();
    for line in maps.lines() {
        let mut fields = line.split_whitespace();
        let (Some(range), Some(perms)) = (fields.next(), fields.next()) else {
            continue;
        };
        if perms.as_bytes().get(1) != Some(&b'w') {
            continue;
        }
        let Some((start, end)) = range.split_once('-') else {
            bail!("unexpected /proc/self/maps line: {line}");
        };
        let start = usize::from_str_radix(start, 16)?;
        let end = usize::from_str_radix(end, 16)?;
        out.push(Span::new(start, end - start));
    }
    Ok(out)
}

#[cfg(target_os = "macos")]
pub fn writable_mappings() -> Result<Vec<Span>> {
    use mach2::{
        kern_return::KERN_SUCCESS,
        traps::mach_task_self,
        vm::mach_vm_region_recurse,
        vm_prot::VM_PROT_WRITE,
        vm_region::vm_region_submap_info_64,
        vm_types::{mach_vm_address_t, mach_vm_size_t, natural_t},
    };

    let mut out = Vec::new();
    let mut addr: mach_vm_address_t = 0;
    let mut depth: natural_t = 0;
    loop {
        let mut size: mach_vm_size_t = 0;
        let mut info: vm_region_submap_info_64 = unsafe { std::mem::zeroed() };
        let mut count = vm_region_submap_info_64::count();
        let kr = unsafe {
            mach_vm_region_recurse(
                mach_task_self(),
                &mut addr,
                &mut size,
                &mut depth,
                (&mut info as *mut vm_region_submap_info_64).cast(),
                &mut count,
            )
        };
        if kr != KERN_SUCCESS {
            break; // past the last region
        }
        if info.is_submap != 0 {
            depth += 1;
            continue;
        }
        if info.protection & VM_PROT_WRITE != 0 {
            out.push(Span::new(addr as usize, size as usize));
        }
        addr += size;
    }
    Ok(out)
}

#[cfg(not(any(target_os = "linux", target_os = "macos")))]
pub fn writable_mappings() -> Result<Vec<Span>> {
    bail!("the runtime region is only supported on Linux and macOS")
}

pub unsafe fn flip_data(addr: usize, bit: u8) {
    let ptr = addr as *mut u8;
    unsafe { ptr.write_volatile(ptr.read_volatile() ^ (1 << bit)) };
}

pub unsafe fn flip_code(addr: usize, bit: u8) -> Result<()> {
    let page = unsafe { libc::sysconf(libc::_SC_PAGESIZE) } as usize;
    let base = (addr & !(page - 1)) as *mut libc::c_void;
    if unsafe { libc::mprotect(base, page, libc::PROT_READ | libc::PROT_WRITE) } != 0 {
        bail!("mprotect(RW) failed: {}", std::io::Error::last_os_error());
    }
    unsafe { flip_data(addr, bit) };
    if unsafe { libc::mprotect(base, page, libc::PROT_READ | libc::PROT_EXEC) } != 0 {
        bail!("mprotect(RX) failed: {}", std::io::Error::last_os_error());
    }
    unsafe { flush_icache(addr, 1) };
    Ok(())
}

#[cfg(all(target_os = "macos", target_arch = "aarch64"))]
unsafe fn flush_icache(addr: usize, len: usize) {
    unsafe extern "C" {
        fn sys_icache_invalidate(start: *mut libc::c_void, len: usize);
    }
    unsafe { sys_icache_invalidate(addr as *mut libc::c_void, len) }
}

#[cfg(not(target_arch = "aarch64"))]
unsafe fn flush_icache(_addr: usize, _len: usize) {}
