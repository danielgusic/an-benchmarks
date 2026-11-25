use core::cell::UnsafeCell;

pub use core::hint::black_box;

pub trait Bench: Sized + 'static {
    fn setup(param: u64) -> Self;

    fn reset(&mut self) {}

    fn run(&mut self, iters: u64) -> u64;

    fn verify(&mut self) -> u64 {
        0
    }
}

#[cold]
pub fn fail() -> ! {
    #[cfg(target_arch = "wasm32")]
    core::arch::wasm32::unreachable();
    #[cfg(not(target_arch = "wasm32"))]
    std::process::abort();
}

#[inline]
pub fn check(cond: bool) {
    if !cond {
        fail();
    }
}

#[inline]
pub fn fold(acc: u64, value: u64) -> u64 {
    (acc.rotate_left(7) ^ value).wrapping_add(0x9e37_79b9_7f4a_7c15)
}

#[derive(Clone, Debug)]
pub struct XorShift64(u64);

impl XorShift64 {
    pub const fn new(seed: u64) -> Self {
        Self(if seed == 0 {
            0x9e37_79b9_7f4a_7c15
        } else {
            seed
        })
    }

    pub fn next_u64(&mut self) -> u64 {
        let mut x = self.0;
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        self.0 = x;
        x
    }

    pub fn next_u32(&mut self) -> u32 {
        (self.next_u64() >> 32) as u32
    }
}

#[doc(hidden)]
pub struct Slot<T>(UnsafeCell<Option<T>>);

unsafe impl<T> Sync for Slot<T> {}

impl<T> Slot<T> {
    #[doc(hidden)]
    pub const fn new() -> Self {
        Self(UnsafeCell::new(None))
    }

    #[doc(hidden)]
    pub unsafe fn set(&self, value: T) {
        unsafe { *self.0.get() = Some(value) }
    }

    #[doc(hidden)]
    #[allow(clippy::mut_from_ref)]
    pub unsafe fn get(&self) -> &mut T {
        match unsafe { (*self.0.get()).as_mut() } {
            Some(value) => value,
            None => fail(),
        }
    }
}

#[macro_export]
macro_rules! bench {
    ($ty:ty) => {
        static __MICRO_ABI_STATE: $crate::Slot<$ty> = $crate::Slot::new();

        #[unsafe(no_mangle)]
        pub extern "C" fn bench_setup(param: u64) {
            unsafe { __MICRO_ABI_STATE.set(<$ty as $crate::Bench>::setup(param)) }
        }

        #[unsafe(no_mangle)]
        pub extern "C" fn bench_reset() {
            <$ty as $crate::Bench>::reset(unsafe { __MICRO_ABI_STATE.get() })
        }

        #[unsafe(no_mangle)]
        pub extern "C" fn bench_run(iters: u64) -> u64 {
            <$ty as $crate::Bench>::run(unsafe { __MICRO_ABI_STATE.get() }, iters)
        }

        #[unsafe(no_mangle)]
        pub extern "C" fn bench_verify() -> u64 {
            <$ty as $crate::Bench>::verify(unsafe { __MICRO_ABI_STATE.get() })
        }
    };
}
