//! The replay on std's HashMap (hashbrown as std vendors it) with FxHasher: tsrs's `FxHashMap`.
type S = rustc_hash::FxBuildHasher;
type Map<K, const N: usize> = std::collections::HashMap<K, [i64; N], S>;
include!("../replay.rs");
