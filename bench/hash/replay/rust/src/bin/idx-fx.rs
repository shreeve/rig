//! The replay on indexmap 2.14.2 (insertion order, as Rig's Map keeps) with rustc-hash 2.1.3's FxHasher.
type S = rustc_hash::FxBuildHasher;
type Map<K, const N: usize> = indexmap::IndexMap<K, [i64; N], S>;
/// `shift_remove`, which keeps the order of the rest, as a take from
/// Rig's Map does (at a cost that grows with the entries after it).
#[inline(always)]
fn take<K: std::hash::Hash + Eq, const N: usize>(m: &mut Map<K, N>, k: &K) -> Option<[i64; N]> {
    m.shift_remove(k)
}
include!("../replay.rs");
