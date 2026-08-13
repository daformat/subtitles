//! Lock-free SPSC ring buffer.
//!
//! One producer (the Core Audio IOProc) and one consumer (the ASR thread).
//! `push` is realtime-safe: no allocation, no locks, no syscalls — see the hard
//! rule in PLAN.md §4.
//!
//! When the consumer falls behind, the producer drops the incoming block rather
//! than blocking. Dropping audio is the correct failure mode for a realtime
//! thread; the drop counter makes it visible instead of silent.

use std::cell::UnsafeCell;
use std::sync::atomic::{AtomicUsize, Ordering};

pub struct Ring {
    buf: UnsafeCell<Box<[f32]>>,
    mask: usize,
    write: AtomicUsize,
    read: AtomicUsize,
    dropped: AtomicUsize,
}

// Safety: exactly one thread calls push() and exactly one calls pop(). The two
// index atomics order all access to the buffer between them.
unsafe impl Send for Ring {}
unsafe impl Sync for Ring {}

impl Ring {
    /// `capacity` is rounded up to a power of two so the index wrap is a mask.
    pub fn new(capacity: usize) -> Self {
        let cap = capacity.next_power_of_two();
        Ring {
            buf: UnsafeCell::new(vec![0.0; cap].into_boxed_slice()),
            mask: cap - 1,
            write: AtomicUsize::new(0),
            read: AtomicUsize::new(0),
            dropped: AtomicUsize::new(0),
        }
    }

    pub fn capacity(&self) -> usize {
        self.mask + 1
    }

    /// Producer side. Realtime-safe.
    ///
    /// Returns false and drops the whole block if it would not fit — a partial
    /// write would tear a frame boundary and desync the channel interleave.
    pub fn push(&self, src: &[f32]) -> bool {
        let w = self.write.load(Ordering::Relaxed);
        let r = self.read.load(Ordering::Acquire);
        let used = w.wrapping_sub(r);
        if used + src.len() > self.capacity() {
            self.dropped.fetch_add(src.len(), Ordering::Relaxed);
            return false;
        }

        // Safety: we own [w, w + src.len()); the consumer only reads below `r`.
        let buf = unsafe { &mut *self.buf.get() };
        let start = w & self.mask;
        let first = src.len().min(self.capacity() - start);
        buf[start..start + first].copy_from_slice(&src[..first]);
        if first < src.len() {
            buf[..src.len() - first].copy_from_slice(&src[first..]);
        }

        self.write.store(w.wrapping_add(src.len()), Ordering::Release);
        true
    }

    /// Consumer side. Returns the number of samples written into `dst`.
    pub fn pop(&self, dst: &mut [f32]) -> usize {
        let r = self.read.load(Ordering::Relaxed);
        let w = self.write.load(Ordering::Acquire);
        let avail = w.wrapping_sub(r).min(dst.len());
        if avail == 0 {
            return 0;
        }

        let buf = unsafe { &*self.buf.get() };
        let start = r & self.mask;
        let first = avail.min(self.capacity() - start);
        dst[..first].copy_from_slice(&buf[start..start + first]);
        if first < avail {
            dst[first..avail].copy_from_slice(&buf[..avail - first]);
        }

        self.read.store(r.wrapping_add(avail), Ordering::Release);
        avail
    }

    /// Used by tests and by the platform layer to observe backlog.
    #[allow(dead_code)]
    pub fn available(&self) -> usize {
        self.write
            .load(Ordering::Acquire)
            .wrapping_sub(self.read.load(Ordering::Relaxed))
    }

    pub fn dropped(&self) -> usize {
        self.dropped.load(Ordering::Relaxed)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn roundtrip_and_wrap() {
        let r = Ring::new(8);
        assert_eq!(r.capacity(), 8);
        assert!(r.push(&[1.0, 2.0, 3.0]));

        let mut out = [0.0; 3];
        assert_eq!(r.pop(&mut out), 3);
        assert_eq!(out, [1.0, 2.0, 3.0]);

        // force the index past the end so the copy splits in two
        for _ in 0..3 {
            assert!(r.push(&[9.0, 9.0, 9.0]));
            let mut o = [0.0; 3];
            assert_eq!(r.pop(&mut o), 3);
            assert_eq!(o, [9.0, 9.0, 9.0]);
        }
    }

    #[test]
    fn drops_whole_block_when_full() {
        let r = Ring::new(4);
        assert!(r.push(&[1.0, 2.0, 3.0, 4.0]));
        assert!(!r.push(&[5.0]));
        assert_eq!(r.dropped(), 1);

        // the earlier data must be intact — a partial write would have corrupted it
        let mut out = [0.0; 4];
        assert_eq!(r.pop(&mut out), 4);
        assert_eq!(out, [1.0, 2.0, 3.0, 4.0]);
    }

    #[test]
    fn pop_returns_only_what_is_available() {
        let r = Ring::new(16);
        r.push(&[1.0, 2.0]);
        let mut out = [0.0; 8];
        assert_eq!(r.pop(&mut out), 2);
        assert_eq!(r.pop(&mut out), 0);
    }
}
