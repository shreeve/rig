# Item 1: Trig against tsrs, function by function (2026-10-31)

pup P-core 6 (sibling idle), Trig aa3994b built with Rig main 08ddd22bc
(plain `--release`), tsrs without PGO, one checker, outputs identical. User
cycles a run (perf stat medians), self cycles by function from perf record
(cycles/u, LBR call branches), scaled to perf stat. Data and scripts:
pup `/zfs/trig-pup/prof-item1/` (run.sh, compare.py, out-core6/compare-*.txt,
NOTES.txt).

| project | Trig Mcycles | tsrs Mcycles | ratio | Trig Minstr | tsrs Minstr |
|---|---:|---:|---:|---:|---:|
| empty (zod3's libraries) | 81.3 | 51.5 | 1.58× | 212.4 | 140.5 |
| mitt | 91.0 | 60.6 | 1.50× | 229.0 | 159.1 |
| zod3 | 734.4 | 644.2 | 1.14× | 1,652.1 | 1,411.8 |
| ts-pattern | 3,848.6 | 3,570.1 | 1.08× | 9,063.3 | 8,142.0 |

## 1. The blocking pool's spin (Rig runtime): 2.2 to 2.6 ms a run

`__rig_std_file.realpath` takes 10.5 to 12.5 Mcycles of user time on every
project: 37% of the empty project's gap, 41% of mitt's, 12% of zod3's, 4% of
ts-pattern's. 99% of it is one loop (perf annotate):

    pause
    movzbl 0x6c(%r14),%eax    ; c.state
    cmp    $0x1,%al           ; == finishing

`sched.poolCall`'s waiter spins while the call is `finishing`: the pool's
thread has set `finishing`, woken the fiber (`interrupt`), and not yet stored
`done`. Pinned to one core, as every one-thread race against tsrs is, the
wake preempts the pool's thread on that core and the waiter spins until the
kernel takes the core back. Unpinned, the window is nanoseconds.

Fix (Rig, src/sched.zig): spin briefly, then yield the thread
(`std.Thread.yield`) while `finishing`, so the pool's thread stores `done`.

## 2. Parse and bind (Trig): most of the rest of the small projects' gap

Empty project, port code 48.3 Mcycles against tsrs's 26.3 by matched name
(tsrs inlines more, so families compare better): `scan` 8.1, `rewind` 3.7,
`set_parent_in_immediate_children` 3.6, `scan_identifier` 3.5,
`bind_declaration` 2.1, `bind_each_child` 1.9, `next_token` 1.3. The lexer
alone is about 17 of the 30 Mcycle gap with the spin removed.

## 3. ts-pattern's check: near parity, spread thin

User cycles 1.08× tsrs (11% more instructions). Where both sides keep a
function whole, inclusive cycles are level or lower in Trig:
`recursive_type_related_to` 1,269 against 1,312 Mcycles,
`resolve_object_type_members` 283 against 338, `is_type_related_to` 1,220
against 1,139, `set_structured_type_members` 163 against 143. The self-cycle
gaps (`instantiate_type_worker` 310, `instantiate_type_with_alias` 204) are
tsrs inlining those into callers whose names Trig lacks: port code by
matched name is +1,293 Mcycles and by unmatched name -1,049. Library code
is level: Trig's allocator and runtime 365 Mcycles against mimalloc,
hashbrown and Rust's std 331. `instantiate_type_with_alias` at 69%
inclusive is the whole checker under it, in tsrs too. ts-pattern's wall gap
beyond its user cycles is the kernel's memory work (standing-4: madvise,
munmap, faults), which is Rig's (row 22).

## 4. Parser follow-up, after trig#231 lands (2026-11-01)

Rig row 40 (direct calls in the compiler) is closed: its pup ceiling gave mitt
2.3% faster, zod3 and ts-pattern level, for changes in five emit paths. Two
Trig-side routes instead, each with a `# Go:` marker and a DIVERGENCE.md row:

- drop `parse_list`'s closure layer (the thunk, about 0.3% of parse samples);
- in `parse_list_index`, call the element function by a `match` on
  ParsingContext, each arm direct (the FnRef call, about 1.9% of parse
  samples; tsrs gets this from monomorphization).

Stack with other small parser items so the change clears the bar (≥1% fewer
instructions or >1.5% faster on 20 pup rounds).

Result (2026-11-01): route (b), a `match` on ParsingContext calling 17 of 21
list kinds' element functions directly (disassembly: plain `bl`), measured
level on the Mac over 11 rounds: empty 0.02% fewer instructions, mitt 0.15%
more, the rest within 0.25%. The 1.9% the profile gave the FnRef thunk was
mostly the element functions' own work. Dropped; diff kept in
parser-direct/route-b.diff. NEEDS 67's figure overstates the call's cost.
