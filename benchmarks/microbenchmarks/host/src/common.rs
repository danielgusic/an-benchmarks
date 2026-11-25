use std::path::{Path, PathBuf};

use anyhow::{Result, bail};
use clap::Args;
use wasmtime::{Config, Engine, Instance, Linker, Module, Store, TypedFunc};

pub const WASM_STACK: usize = 512 * 1024;

pub trait Context<T> {
    fn context(self, msg: &'static str) -> Result<T>;
    fn with_context(self, msg: impl FnOnce() -> String) -> Result<T>;
}

impl<T> Context<T> for wasmtime::Result<T> {
    fn context(self, msg: &'static str) -> Result<T> {
        self.map_err(|e| anyhow::Error::from(e).context(msg))
    }

    fn with_context(self, msg: impl FnOnce() -> String) -> Result<T> {
        self.map_err(|e| anyhow::Error::from(e).context(msg()))
    }
}

#[derive(Args, Clone, Debug)]
pub struct GuestOpts {
    pub wasm: PathBuf,

    #[arg(long)]
    pub an: bool,

    #[arg(long, value_name = "A", requires = "an")]
    pub an_constant: Option<u64>,

    #[arg(long, value_name = "N", default_value_t = 0)]
    pub param: u64,

    #[arg(long, value_name = "N", default_value_t = 1)]
    pub iters: u64,

    #[arg(long, value_parser = parse_name)]
    pub name: Option<String>,
}

impl GuestOpts {
    pub fn name(&self) -> String {
        self.name.clone().unwrap_or_else(|| {
            self.wasm
                .file_stem()
                .unwrap_or(self.wasm.as_os_str())
                .to_string_lossy()
                .into_owned()
        })
    }

    pub fn mode(&self) -> &'static str {
        if self.an { "an" } else { "off" }
    }

    pub fn an_constant_column(&self) -> String {
        match (self.an, self.an_constant) {
            (true, Some(a)) => a.to_string(),
            (true, None) => "default".to_string(),
            (false, _) => String::new(),
        }
    }

    pub fn engine(&self) -> Result<Engine> {
        let mut config = Config::new();
        config.max_wasm_stack(WASM_STACK);
        if self.an {
            config.an_encoding(true);
            if let Some(a) = self.an_constant {
                config.an_constant(a);
            }
        }
        Ok(Engine::new(&config)?)
    }
}

fn parse_name(name: &str) -> Result<String, String> {
    if name.is_empty() || name.contains(',') {
        Err("must be non-empty and must not contain commas".into())
    } else {
        Ok(name.to_string())
    }
}

pub fn compile(engine: &Engine, wasm: &Path) -> Result<Module> {
    let module = Module::from_file(engine, wasm)
        .with_context(|| format!("failed to compile {}", wasm.display()))?;
    let imports: Vec<String> = module
        .imports()
        .map(|i| format!("{}.{}", i.module(), i.name()))
        .collect();
    if !imports.is_empty() {
        bail!(
            "guest must not import anything, but imports: {}\n\
             (C guests: link with -mexec-model=reactor and avoid libc functions that need WASI)",
            imports.join(", ")
        );
    }
    Ok(module)
}

pub struct Guest {
    pub instance: Instance,
    setup: Option<TypedFunc<u64, ()>>,
    reset: Option<TypedFunc<(), ()>>,
    pub run: TypedFunc<u64, u64>,
    verify: Option<TypedFunc<(), u64>>,
    initialize: Option<TypedFunc<(), ()>>,
}

pub enum Phase {
    Run,
    Verify,
}

impl Guest {
    pub fn instantiate(store: &mut Store<()>, module: &Module) -> Result<Self> {
        let instance = Linker::new(store.engine()).instantiate(&mut *store, module)?;
        Self::new(store, instance)
    }

    fn new(store: &mut Store<()>, instance: Instance) -> Result<Self> {
        fn optional<P, R>(
            store: &mut Store<()>,
            instance: &Instance,
            name: &str,
            ty: &'static str,
        ) -> Result<Option<TypedFunc<P, R>>>
        where
            P: wasmtime::WasmParams,
            R: wasmtime::WasmResults,
        {
            if instance.get_func(&mut *store, name).is_none() {
                return Ok(None);
            }
            Ok(Some(
                instance
                    .get_typed_func::<P, R>(&mut *store, name)
                    .with_context(|| format!("{name} must have type {ty}"))?,
            ))
        }
        let setup = optional(store, &instance, "bench_setup", "(i64) -> ()")?;
        let reset = optional(store, &instance, "bench_reset", "() -> ()")?;
        let initialize = optional(store, &instance, "_initialize", "() -> ()")?;
        let verify = optional(store, &instance, "bench_verify", "() -> i64")?;
        let Some(run) = optional(store, &instance, "bench_run", "(i64) -> i64")? else {
            bail!("guest does not export bench_run");
        };
        Ok(Self {
            instance,
            setup,
            reset,
            run,
            verify,
            initialize,
        })
    }

    pub fn checksum(
        &self,
        store: &mut Store<()>,
        run: wasmtime::Result<u64>,
    ) -> Result<u64, (Phase, wasmtime::Error)> {
        let value = run.map_err(|e| (Phase::Run, e))?;
        match &self.verify {
            Some(verify) => Ok(value
                ^ verify
                    .call(&mut *store, ())
                    .map_err(|e| (Phase::Verify, e))?),
            None => Ok(value),
        }
    }

    pub fn setup(&self, store: &mut Store<()>, param: u64) -> Result<()> {
        if let Some(init) = &self.initialize {
            init.call(&mut *store, ())
                .context("guest trapped in _initialize")?;
        }
        if let Some(setup) = &self.setup {
            setup
                .call(&mut *store, param)
                .context("guest trapped in bench_setup")?;
        }
        Ok(())
    }

    pub fn reset(&self, store: &mut Store<()>) -> Result<()> {
        if let Some(reset) = &self.reset {
            reset
                .call(&mut *store, ())
                .context("guest trapped in bench_reset")?;
        }
        Ok(())
    }
}
