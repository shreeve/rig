//! The replay on hashbrown 0.17.1 with rustc-hash 2.1.3's FxHasher, as tsrs hashes.
type S = rustc_hash::FxBuildHasher;
type Map<K, const N: usize> = hashbrown::HashMap<K, [i64; N], S>;
#[inline(always)]
fn take<K: std::hash::Hash + Eq, const N: usize>(m: &mut Map<K, N>, k: &K) -> Option<[i64; N]> {
    m.remove(k)
}
include!("../replay.rs");
