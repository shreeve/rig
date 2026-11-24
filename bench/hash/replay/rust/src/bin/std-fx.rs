//! The replay on std's HashMap (hashbrown as std vendors it) with FxHasher: tsrs's `FxHashMap`.
type S = rustc_hash::FxBuildHasher;
type Map<K, const N: usize> = std::collections::HashMap<K, [i64; N], S>;
#[inline(always)]
fn take<K: std::hash::Hash + Eq, const N: usize>(m: &mut Map<K, N>, k: &K) -> Option<[i64; N]> {
    m.remove(k)
}
include!("../replay.rs");
