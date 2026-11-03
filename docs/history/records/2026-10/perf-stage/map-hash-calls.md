# Beat-tsrs item 22: Map, hash and interner calls (2026-11-02)

Measured only, from the gap map's profiles (pup E-core 13, one checker,
/zfs/trig-pup/prof-item1/out-gap; Trig 07e4447 + #244 by Rig 43e1f65).
Mcycles a run, self cycles scaled to perf stat's user cycles. Scripts:
`lib.py DIR` (library by the function's own crate), `fam22.py DIR [1]`
(Trig's runtime/std by function, Ordered by method), `callers.py DIR RE`
(sampled call edges into RE, from the `-j any_call` stacks).

## 1. The 262 is mostly accounting

The gap map's `fam.py` puts a tsrs symbol in a checker family whenever
`tsrs_checker` appears anywhere in it, generic arguments included. So
`<hashbrown::raw::RawTable<P<Type>>>::reserve_rehash::<ReferenceInstantiations::add…>`
counts as checker work. Classified by the function's own crate:

| | Trig ts-pattern | tsrs ts-pattern | Trig zod3 | tsrs zod3 |
|---|---:|---:|---:|---:|
| map (out of line) | 119.8 | 168.3 | 17.0 | 34.6 |
| sort (+ Trig's FnRef thunks) | 39.4 | 38.0 | 6.8 | 7.3 |
| vec growth | 40.7 | 12.4 | 5.3 | 2.9 |
| interner | 17.5 | (in map) | 10.2 | (in map) |
| mem.eql | 14.3 | | 8.0 | |
| drop / clone | 11.9 | | 1.6 | |
| string, fmt, io | 11.0 | 4.3 | 4.4 | 2.9 |
| hash (out of line) | 7.4 | 0.6 | 5.0 | 0.1 |
| other | 0.2 | 3.2 | 0.3 | 1.0 |
| **all, less alloc** | **262.1** | **226.8** | **58.7** | **48.8** |
| gap, % of Trig | | **0.7%** | | **1.1%** |

tsrs's out-of-line hashbrown growth alone is 148 Mcycles on ts-pattern
(`reserve_rehash`).

## 2. Call overhead and re-hashing

- **Map lookups are already inline.** `find`, `get`, `edit`, `put`,
  `ensure` and `take` are `inline` in src/ordered.zig. The Ordered
  functions that show up are slow paths:
  - `rebuild` (growth): 58.9 Mcycles;
  - `probePastHome`: 30.3;
  - `placePast`: 16.0;
  - small-table growth and entry resizes: 12.8.
  Trig's 120 against tsrs's 168 means Rig's table is cheaper here.
- **The overflow walks are not a hash defect.** The two-word hash
  (`hashWords`) spreads sequential, constant and grid key pairs like
  random keys in a simulation. The walks follow from the 0.875 load
  limit.
- **Re-hashing the same key is Trig's.** `Checker.atom(s)` hashes `s`
  in `names.find`, and on a miss hashes it again in `own_names.intern`.
  74 sites call `atom("literal")`. `is_function_object_type` does
  `atom("bind")` on every call, and makes 26.5% of zod3's
  `Interner.find` calls. `get_resolved_symbol` re-interns the identifier's
  text. Each lookup is three out-of-line calls: `Interner.find`,
  `hashBytes` (Wyhash) and `mem.eqlBytes`. The interner path costs
  about 28 Mcycles on ts-pattern (0.57%) and 17 on zod3 (1.8%).
- **Vec growth** (41 against 12) comes from Trig's per-call temporary
  Lists: `invoke_once`, `get_conditional_type_worker`, `mapper_map`'s
  clones. Rig's policy (4, then doubling) matches Rust's.

## 3. What an inline hit path would save

- **Maps:** nothing. The hit path is already inline.
- **Interner:** inlining `find` with a short-string hash and an inline
  compare removes the calls but not the work. Estimate 0.2% on
  ts-pattern and 0.5–0.9% on zod3. This is under 1%, so no ceiling.
  It also shrinks once Trig stops re-interning constants.

## Leads, not Rig's

These are Trig's; forward them raw.
1. Atoms for the checker's literal names made once, at checker setup
   (`bind` and the other 73).
2. `get_resolved_symbol` and its siblings take the identifier's atom
   from the binder, rather than hashing its text again.
3. `Checker.atom` looks in one table.

Reach up to about 0.5% on ts-pattern and 1.5% on zod3.

Also: fix `fam.py`'s rule (classify by the function's own crate) before
the next gap map.
