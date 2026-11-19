//! Matrix products as the Swift code computes them: Apple's Accelerate (vDSP) on macOS, so sums
//! come out bit for bit the same (the sound map's layout magnifies any difference), and plain
//! loops elsewhere, as the Swift code does where there's no Accelerate.
//!
//! vDSP's sums depend on where the matrix sits in memory (moving it by one float changed 167 of
//! 206 products, 2026-10-29), so the big matrices live where the Swift app keeps them:
//! `Floats::page` as its `PageBuffer` (page-aligned), `Floats::array` as a Swift array's storage
//! (32 bytes past a page boundary).

use std::alloc::{Layout, alloc_zeroed, dealloc};
use std::ops::{Deref, DerefMut};

/// Floats at a chosen place in memory, starting as zeros.
pub struct Floats {
    ptr: *mut f32,
    len: usize,
    layout: Layout,
    offset: usize,
}

// The buffer owns its memory like a Vec does.
unsafe impl Send for Floats {}
unsafe impl Sync for Floats {}

impl Floats {
    const PAGE: usize = 16_384;

    fn new(len: usize, offset_bytes: usize) -> Floats {
        let size = (len * 4 + offset_bytes).max(1);
        let layout = Layout::from_size_align(size, Self::PAGE).expect("a valid layout");
        // SAFETY: the layout has a non-zero size.
        let base = unsafe { alloc_zeroed(layout) };
        assert!(!base.is_null(), "out of memory");
        Floats {
            ptr: unsafe { base.add(offset_bytes) } as *mut f32,
            len,
            layout,
            offset: offset_bytes,
        }
    }

    /// As the Swift app's `PageBuffer`: page-aligned.
    pub fn page(len: usize) -> Floats {
        Floats::new(len, 0)
    }

    /// As a Swift array's storage: its header takes the first 32 bytes of a page-aligned block.
    pub fn array(len: usize) -> Floats {
        Floats::new(len, 32)
    }

    pub fn page_from(values: &[f32]) -> Floats {
        let mut f = Floats::page(values.len());
        f.copy_from_slice(values);
        f
    }
}

impl Drop for Floats {
    fn drop(&mut self) {
        // SAFETY: allocated in `new` with this layout, `offset` bytes before `ptr`.
        unsafe { dealloc((self.ptr as *mut u8).sub(self.offset), self.layout) }
    }
}

impl Deref for Floats {
    type Target = [f32];
    fn deref(&self) -> &[f32] {
        // SAFETY: `len` floats were allocated and zeroed in `new`.
        unsafe { std::slice::from_raw_parts(self.ptr, self.len) }
    }
}

impl DerefMut for Floats {
    fn deref_mut(&mut self) -> &mut [f32] {
        // SAFETY: as above; `&mut self` makes this the only reference.
        unsafe { std::slice::from_raw_parts_mut(self.ptr, self.len) }
    }
}

#[cfg(target_os = "macos")]
#[link(name = "Accelerate", kind = "framework")]
unsafe extern "C" {
    fn vDSP_mmul(
        a: *const f32,
        ia: isize,
        b: *const f32,
        ib: isize,
        c: *mut f32,
        ic: isize,
        m: usize,
        n: usize,
        p: usize,
    );
    fn vDSP_mtrans(a: *const f32, ia: isize, c: *mut f32, ic: isize, m: usize, n: usize);
}

/// c (m × n) = a (m × p) · b (p × n), row-major.
pub fn mmul(a: &[f32], b: &[f32], c: &mut [f32], m: usize, n: usize, p: usize) {
    assert!(a.len() >= m * p && b.len() >= p * n && c.len() >= m * n);
    #[cfg(target_os = "macos")]
    unsafe {
        vDSP_mmul(a.as_ptr(), 1, b.as_ptr(), 1, c.as_mut_ptr(), 1, m, n, p);
    }
    #[cfg(not(target_os = "macos"))]
    for i in 0..m {
        for j in 0..n {
            let mut s = 0f32;
            for k in 0..p {
                s += a[i * p + k] * b[k * n + j];
            }
            c[i * n + j] = s;
        }
    }
}

/// c (n × m) = a (m × n) transposed.
pub fn transpose(a: &[f32], c: &mut [f32], m: usize, n: usize) {
    assert!(a.len() >= m * n && c.len() >= m * n);
    #[cfg(target_os = "macos")]
    unsafe {
        vDSP_mtrans(a.as_ptr(), 1, c.as_mut_ptr(), 1, n, m);
    }
    #[cfg(not(target_os = "macos"))]
    for i in 0..m {
        for j in 0..n {
            c[j * m + i] = a[i * n + j];
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn products_and_transposes() {
        let a = [1.0, 2.0, 3.0, 4.0, 5.0, 6.0]; // 2 × 3
        let b = [1.0, 0.0, 0.0, 1.0, 1.0, 1.0]; // 3 × 2
        let mut c = [0.0; 4];
        mmul(&a, &b, &mut c, 2, 2, 3);
        assert_eq!(c, [4.0, 5.0, 10.0, 11.0]);
        let mut t = [0.0; 6];
        transpose(&a, &mut t, 2, 3);
        assert_eq!(t, [1.0, 4.0, 2.0, 5.0, 3.0, 6.0]);
    }

    #[test]
    fn floats_sit_where_swift_keeps_them() {
        let p = Floats::page(1000);
        assert_eq!(p.as_ptr() as usize % Floats::PAGE, 0);
        assert!(p.iter().all(|&v| v == 0.0));
        let a = Floats::array(10);
        assert_eq!(a.as_ptr() as usize % Floats::PAGE, 32);
        assert_eq!(Floats::page_from(&[1.0, 2.0])[..], [1.0, 2.0]);
        assert_eq!(Floats::page(0).len(), 0);
    }
}
