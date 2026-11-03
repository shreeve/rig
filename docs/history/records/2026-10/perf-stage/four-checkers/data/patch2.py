#!/usr/bin/env python3
"""Second counter round (60-70) on the already-patched scratch copies.
patch2.py trig ROOT | patch2.py tsrs ROOT. tsrs counters become per thread
(`CK0 <slot> <i> <v>`), so checker 0's thread can be told apart."""
import sys, re
which, root = sys.argv[1], sys.argv[2]

def patch(path, pairs):
    p = f'{root}/{path}'
    s = open(p).read()
    for old, new in pairs:
        n = s.count(old)
        if n != 1:
            sys.exit(f'{path}: {n} matches for {old[:80]!r}')
        s = s.replace(old, new)
    open(p, 'w').write(s)

def after_head(path, head, line):
    """Insert `line` right after the line starting with `head` (a function
    header, possibly continued over several lines up to its first `{` for Rust)."""
    p = f'{root}/{path}'
    s = open(p).read()
    i = s.find(head)
    if i < 0 or s.find(head, i + 1) >= 0:
        sys.exit(f'{path}: head not unique: {head[:70]!r}')
    if which == 'tsrs':
        j = s.find('{\n', i) + 2
    else:
        j = s.find('\n', i) + 1
    s = s[:j] + line + s[j:]
    open(p, 'w').write(s)

if which == 'trig':
    C = 'checker'
    T = lambda i: f'  ck_add_to(!@ck, {i}, 1)\n'
    after_head(f'{C}/relater.rig', 'pub fun Checker.is_related_to_ex(', T(60))
    after_head(f'{C}/relater.rig', 'pub fun Checker.structured_type_related_to(', T(61))
    patch(f'{C}/relater.rig', [
        ("    related = (?@).relation_get(relation, id)\n", "    ck_add_to(!@ck, 62, 1)\n    related = (?@).relation_get(relation, id)\n"),
        ("  entry = (?@).relation_get(relation, id)\n", "  ck_add_to(!@ck, 62, 1)\n  entry = (?@).relation_get(relation, id)\n"),
    ])
    after_head(f'{C}/modules.rig', 'pub fun Checker.get_type_of_symbol(', T(63))
    after_head(f'{C}/members.rig', 'called fun Checker.resolve_structured_type_members_worker(', T(64))
    after_head(f'{C}/inference.rig', 'pub sub Checker.infer_types(', T(65))
    after_head(f'{C}/inference.rig', 'pub sub Checker.infer_from_types(', T(66))
    after_head(f'{C}/members.rig', 'pub fun Checker.get_signatures_of_type(', T(67))
    after_head(f'{C}/declarations.rig', 'pub fun Checker.get_property_of_type_ex(', T(68))
    after_head(f'{C}/constructors.rig', 'pub fun Checker.get_union_type_ex(', T(69))
    after_head(f'{C}/members.rig', 'pub fun Checker.get_intersection_type_ex(', T(70))
else:
    S = 'crates/tsrs_checker/src'
    open(f'{root}/{S}/ck0.rs', 'w').write('''//! CK0 call counters (scratch), one row per thread.
use std::cell::Cell;
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
const SLOTS: usize = 16;
pub static C: [[AtomicU64; 100]; SLOTS] = [const { [const { AtomicU64::new(0) }; 100] }; SLOTS];
static NEXT: AtomicUsize = AtomicUsize::new(0);
thread_local! { static SLOT: Cell<usize> = const { Cell::new(usize::MAX) }; }
#[inline(always)]
pub fn add(i: usize, n: u64) {
    let s = SLOT.with(|c| {
        let mut s = c.get();
        if s == usize::MAX {
            s = NEXT.fetch_add(1, Ordering::Relaxed).min(SLOTS - 1);
            c.set(s);
        }
        s
    });
    C[s][i].fetch_add(n, Ordering::Relaxed);
}
pub fn dump() {
    for (s, row) in C.iter().enumerate() {
        for (i, c) in row.iter().enumerate() {
            let v = c.load(Ordering::Relaxed);
            if v != 0 {
                println!("CK0 {} {} {}", s, i, v);
            }
        }
    }
}
''')
    R = lambda i: f'        crate::ck0::add({i}, 1);\n'
    after_head(f'{S}/relater_2.rs', '    pub(crate) fn is_related_to_ex(', R(60))
    after_head(f'{S}/relater_2.rs', '    pub(crate) fn structured_type_related_to(', R(61))
    after_head(f'{S}/relater_1.rs', '    pub(crate) fn lookup(&self, key: RelationKey)', R(62))
    after_head(f'{S}/checker_08.rs', '    pub fn get_type_of_symbol(&mut self, symbol: P<Symbol>)', R(63))
    patch(f'{S}/checker_09.rs', [(
        "    ) -> &'static StructuredType {\n        #[cfg(feature = \"site-counts\")]\n        if !t.object_flags_lazy().intersects(ObjectFlags::MembersResolved) {\n",
        "    ) -> &'static StructuredType {\n        if !t.object_flags_lazy().intersects(ObjectFlags::MembersResolved) { crate::ck0::add(64, 1); }\n        #[cfg(feature = \"site-counts\")]\n        if !t.object_flags_lazy().intersects(ObjectFlags::MembersResolved) {\n")])
    after_head(f'{S}/inference.rs', '    pub(crate) fn infer_types(', R(65))
    after_head(f'{S}/inference.rs', '    pub(crate) fn infer_from_types(', R(66))
    after_head(f'{S}/checker_09.rs', '    pub fn get_signatures_of_type(', R(67))
    after_head(f'{S}/checker_09.rs', '    pub(crate) fn get_property_of_type_ex(', R(68))
    after_head(f'{S}/checker_12.rs', '    pub fn get_union_type_ex(', R(69))
    after_head(f'{S}/checker_13.rs', '    pub(crate) fn get_intersection_type_ex(', R(70))
print('patched', which)
