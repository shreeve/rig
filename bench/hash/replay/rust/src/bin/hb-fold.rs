//! The replay on hashbrown 0.17.1 with foldhash 0.2.0, its default (fixed seed).
type S = foldhash::fast::FixedState;
type Map<K, const N: usize> = hashbrown::HashMap<K, [i64; N], S>;
include!("../replay.rs");
