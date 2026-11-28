# The rebuild ledger

The running state of the rebuild ([rebuild.md](../../../internals/rebuild.md),
[architecture.md](../../../internals/architecture.md)). The lead keeps
it: builders report, and the lead records each step as it is claimed and
as it lands. Newest entries first.

## Base

- Rig: tag `revamp-base`, commit 645996606.
- Trig: tag `trig-revamp-base`, commit f876e4b2, pinned to `revamp-base`.
- Baseline record: `docs/history/records/2026-11/revamp-base/` (in progress).

## Steps

| Step | Kind | Track | Builder | State | PR | Net source lines |
|---|---|---|---|---|---|---:|
| Pilot front F1: the recorder's trail | I | front | pilot-front | merged | #1258 | +232 |
| Front F2: byte literals, by statement re-check (redesigned) | I | front | front | claimed | | |
| Front F4–F6: chains, option groups and spreads; the module loop deleted | I | front | front | claimed | | |
| Front 5: one decider per fact (shared columns, place walker, builtin column) | I | front | deciders | in review | #1283 | −6 |
| Pilot front F3: iterator loops at the `for` | I | front | pilot-front | merged | #1259 | +70 |
| Pilot back: the var table | I | back | pilot-back | merged | #1256 | +20 |
| Back 1: LIR in shadow | I | back | back | claimed | | |
| Back: `field_moves` into `Binding` | I | back | | next | | |
| LLVM bitcode measurement | experiment | side | llvm-probe | done: yes, with conditions | | |

## Line scoreboard

Lines at `revamp-base`, at the close (v0.4.0, 2026-11-27), and the
budget (architecture.md, "Line budgets"; emit's and ownership's as the
typed-ops design set them again). Blank where a pass's files no longer
match the row's.

| Pass | revamp-base | Now | Budget |
|---|---:|---:|---:|
| front end | about 9,100 | | 7,000 |
| modules and driver | 1,172 | | 950 |
| declare | about 6,700 | | 4,800 |
| types | about 9,000 | | 6,000 |
| recorder | about 4,700 | | 1,200 |
| elaborate and its splits | about 28,300 | | 19,000 |
| cteval | 2,175 | 2,671 | 2,000 |
| LIR | 0 | 1,281 | 1,000 |
| lower (storage at base) | 2,774 | 4,406 | 6,000 |
| ownership | 9,768 | 11,508 | about 9,000 (was 6,000) |
| proofs | 2,930 | 2,731 | 2,000 |
| decide | about 2,500 | | 2,000 |
| print and type layout (emit and facts) | 14,192 | 13,470 | about 12,000 (was 8,000) |

## Entries

### 2026-11-26 to 27: the close

- **The rebuild is closed.** Emit with facts ends at 13,470 lines
  against about 12,000, and ownership at 11,508 against about 9,000.
  Emit reaches its budget only by merging its argument path and its
  answers into the call record (E3 and E4; E5, places in emit, was
  decided no: `e5-places-design.md` in the lead's notes); ownership
  only by a region-driven transfer, one function per LIR step kind, a
  design round, since what remains is the walk itself (transfer.zig,
  4,380 lines) and diagnostic variants input can reach. Both go to the
  cleanup round, then the v1.0 language list, under the owner's review.
- Landed, with each PR's measurement (Trig's `rig check` on the Mac
  unless it says otherwise; "identity" means emit-diff identical and
  own-diff 0 over about 12,085 programs and Trig):
  - #1311 (own-swap 7), identity: match guards, templates' slots,
    labeled constructs, and captures take their operands from LIR.
    Ownership 10,911 to 10,941.
  - #1313 and #1314 (emit-lir F1 to F3), identity: emit reads each
    value's coercions and erased copies from its LIR, and asks facts
    through two lists, `facts.node` and `facts.layout`. Check guard
    4.0% under guard.txt.
  - #1316, inlining judged after callees (`inlining.trim`): 2 of 38
    programs differ (Trig, bench/bigint), every hunk an inline switch;
    fixes #1306's 0.106% more instructions on Trig's checker.
  - #1317, identity: the compiler and the runtime share `arith.zig`
    and `names.zig`; net +78 lines, 45 duplicate lines gone.
  - #1318, identity: lowering makes its own rejections; message text
    identical; net +52.
  - #1319, identity: the walk finds LIR for every part it reads; Trig
    16.38-16.42G instructions, equal; ownership +73.
  - #1320, a statement that is an expression counts as its
    operations: std.json's instructions per byte back at guard.txt's.
  - #1321 (L0), #1328, #1329, #1331 (L1), #1333, identity: typed
    operations: `lir.OpKind`, `lir.Call` (49 forms of `lir.CallKind`),
    operand roles, places, the answers as fields, and `answerAll`
    gone. L0 +654 lines (0.9% more instructions on Trig, 16.413G to
    16.555G, then recovered); L1 +540; the answers -43.
  - #1334 (O1), identity: ownership reads a call's callee, self, held
    parts, and implicit views from lowering: Trig 16.41G on main,
    16.43G at the tip; peak 419 MB unchanged.
  - #1335 (E1, E2), identity: emit writes a call by one switch over
    its kind and the wrappers lowering recorded: emit.zig -177 lines;
    Trig's `rig emit` 0.8% fewer instructions.
  - #1336 (own-region F2), #1337 (F1 slices 1 and 2), #1339 (slice 3),
    identity: hidden vars end where their region ends, and the walk
    goes region by region. Ownership 10,599 to 10,702 (F2), 10,654
    (F1), 10,638 (slice 3); slices 1 and 2 0.4% fewer instructions on
    Trig.
  - #1332, the module's maps grow in the module's arena (a
    use-after-free a self-check build now faults on); #1330, a signal
    stops a task at any stack pointer on x86-64; #1340, a supervised
    actor's methods always run on its own task.
  - #1341 (emit-lir F4), identity: the storage deciders live in
    lowering and `storage.zig` is gone; net -44 lines; Trig 0.14% more
    instructions, inside the spread.
  - #1342, loans end at their last use on the LIR's flow (family P):
    own-diff 125 of 12,096 programs differ, 50 newly accepted, 0 newly
    rejected, 75 notes only, Trig the same; emit identical; Trig
    16.178G instructions against 16.392G (1.3% fewer), peak 399.8 MB
    against 400.2 MB; check guard 5.1% under guard.txt. The positional
    machinery is deleted.
  - #1343, `par` `cost:`: costliest first, claimed by the cost left;
    six giants among 2,000 small items 69.0 ms to 50.2 ms (27% less
    time); emit unchanged without `cost:`.
  - #1344, a float type's limits through an alias are constants of it
    (newly rejected, in the release notes); Trig's and loco's light
    gates GREEN; check guard 0.7% over baseline.
  - #1345, an unlisted oracle difference fails the run; 109 entries
    added, 224 in all.
  - #1346, CORE review 3: a call evaluates its arguments in the order
    it writes them; own-diff 11 of 12,132 newly accepted, none newly
    rejected; emit identical; check guard within 0.02%.
  - #1347, ownership trim: the tree fallback and the copied-argument
    hold go; ownership 11,545 to 11,508; own-diff 0, emit identical.
  - #1348, docs/design/reactivity.md; #1349, cases for 18 emit.zig
    blocks no test reached.
- The release branch deletes what #1347 left dead in lowering: the
  operand's `held` flag, which nothing read, and `holdsParts` and
  `checkedCall` are no longer `pub`; emit-diff identical against
  main.

### 2026-11-25 to 26: v0.4.0

- **v0.4.0** carries the rebuild's steps below. `rig check` of Trig takes 1.95 s and 397 MB, where it
  took 3.95 s and 620 MB at `revamp-base` (burst, under load, fastest
  of 7, measured by Trig's session).
- Landed, with each PR's measurement (Trig's `rig check` on the Mac
  unless it says otherwise; "identity" means emit-diff identical):
  - #1287, a generic instance checked once for the program: the check
    guard 0.9% fewer instructions; Trig level (1,142.5 ms against
    1,146.3 ms, median of 20), since instance checks are under 1% of
    its time.
  - #1291, #1296, #1297 (M3 5a to 5d, and 7), identity: a type's
    symbols read at their home, another module's generic types and
    parameters named by their declaration's ref with the proxies
    deleted, and the built-ins registered once, in module 0. Net
    lines +49, −50, and −17.
  - #1294 and #1300, after #1293, identity: the facts about a leaf, and
    the names, keyed by its leaf id in dense arrays. Trig 4.8% faster
    than main (1,157.6 to 1,102.4 ms), 1.3% fewer instructions, peak
    1.2 MB higher; over the whole leaf-id step, 5.8% faster and peak
    1.16 MB lower.
  - #1298, a behaviour step, every hunk neutral: a temporary made
    before its statement can act goes into its slot ahead of the
    statement; `rig.keep(` falls from 1,421 sites to 334 over the
    emit-diff corpus. Trig's release binary 375 KB (0.2%) smaller;
    `rig check` level; the json, hash, and text guards within 2%.
  - #1299, #1305, #1307, #1308, #1309 (own-swap 1 to 5), identity: the
    ownership checker walks each body's LIR, its operands, statements,
    calls, and entries, and the expression index and the shadow are
    deleted. Against main before the stack, 7.3% fewer instructions
    (18.332G to 16.999G) and 2.5 MB less peak; the ownership pass about
    282 to 225 ms (#1308). Ownership's lines went 11,017 to 11,007.
  - #1301, the runtime takes one config record from the program: check
    guard 0.1% more; Trig's release binary 232 bytes larger.
  - #1302, one checked index and one duration conversion per operation:
    net source −29; Trig's release binary 0.75% larger, all of it debug
    information.
  - #1303, each emitted type carries the checkers' classification:
    check guard 0.6% fewer; Trig's release binary 27,584 bytes (0.016%)
    larger, the markers' cost.
  - #1304, a member of another module, and an integer type's range,
    found by one lookup each, identity: net source −42; check guard
    0.09% fewer.
  - #1306, frames and inlining counted on LIR, a behaviour step with
    every hunk classified: 137 Trig functions flip `inline`; a Mac race
    of 6 projects, 20 rounds, no change beyond the bar; the json guard
    within 0.4% of main. Net source +216.
  - #1312, the test runners construct with `X.new`, as Rip 4.0
    requires.
- Also landed 2026-11-25, each recorded in its PR: #1270 to #1286,
  #1288 (one evaluator), #1289, #1290 (proofs on LIR), #1292, #1293,
  and #1295 (the ownership shadow). #1310 and #1311 (own-swap 6 and 7)
  are drafts.
- **The finding:** ownership (11,030 lines with its unit tests, about
  10,600 without, against 6,000) and emit with facts (13,940 against
  8,000) do not reach their budgets by walking LIR. Moving onto LIR
  deletes their copies of its structure, family by family, but both
  still dispatch on the node: how each call and place is written, and
  which transfer applies. The budgets need typed operations, where
  lowering picks each call's kind and each place's path once. A design
  round shared by emit and ownership comes first, then ownership's
  region-driven transfer and emit's printing from LIR, then the two
  budgets set again for the owner's approval.

### 2026-11-25, later

- The front pilot landed (#1258, #1259): a `for` over an iterator is
  checked where it stands, so 16 of Trig's 54 modules, 74% of its
  lines, no longer take a second sema round. `rig check` on Trig went
  from 2,131 ms to 1,454 ms (31.8% faster, 30% fewer instructions, the
  same peak memory). Emit-diff identical on 38 programs, Trig included;
  Trig's and loco's light gates GREEN. The loop-free check guard
  workload retires 0.6% more instructions, cause not found; the owner
  accepted the trade and guard.txt carries the new baseline. The
  pilot's +302 lines come back when F6 deletes the module loop.
- The pilot found that the trail needs only fact writes: symbols,
  scopes, and interning join it when a step needs them, and type-id
  order does not reach emitted text.
- F2 is redesigned: re-check the enclosing statement, since rewriting a
  literal leaf in place changed std's emit.
- The LLVM bitcode measurement answered yes, with conditions: a
  per-program Zig shim instantiating the runtime's generic code behind
  C entry points; LTO through LLD on Linux, a merged compile on macOS;
  Zig's target features copied, Rig's code kept in its section. Error
  unions, preemption of IR code, and build time are unknown. Kept in
  the lead's notes until December.

### 2026-11-25

- The back pilot landed (#1256): `storage.plan` keeps one var table
  that emit and the ownership checker read, in place of the storage
  map, `part_drops`, `Symbol.hold`, the lazily decided `drop_kind`, and
  the consumed set. Emit-diff identical on all 38 programs, Trig
  included; core suite 12,743 jobs, none died; the oracle unchanged;
  the check guard 0.1% fewer instructions; Trig's and loco's light
  gates GREEN.
- **The pilot's finding:** it was budgeted −500 source lines and landed
  +20. The table adds lines, and each of emit's 56 hidden-storage sites
  still writes its own Zig; the saving comes when emit prints vars
  from the table, the back track's printer step. A step's budget counts
  only the lines that step itself can delete.
- `emit-diff` compares Trig from a plain export (#1260), and a Trig it
  cannot compare fails the proof.
- The before state is race 761 (Trig's research 34): 16 projects, Trig
  over tsrs 0.889 / 0.923 / 0.933 / 0.917 at 1, 2, 4, and 8 checkers;
  race 760 was void (other projects' jobs ran during it), and board
  slots run inside `cpuq run --exclusive`.

### 2026-11-24

- The owner approved rebuild.md (#1252), the baseline tag, and
  architecture.md with its four defaults (#1254): two pilots in
  parallel, sema once in elaborate, and the LLVM bitcode measurement
  as a side experiment.
- Pilots claimed: front (F1–F3) and back (the var table), on disjoint
  files. The LLVM bitcode measurement claimed as a side experiment.
- Baseline: the full suite at `revamp-base` passed 12,783 of 12,783 on
  burst. Trig's light gate is GREEN. The pup timing of the build, the
  check, and the benches, and Trig's race, are still running.
