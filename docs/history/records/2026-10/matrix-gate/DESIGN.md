# Gate the matrix's builds, not only its verdicts

Rig language analysis, 2026-11-01, written during row 53.

## The gap

`swarm test/rig.rip all` runs `test/matrix.py --oracle` (test/rig.rip:687, :1028). That compares
the matrix's verdicts, but never builds the 16,239 programs or runs them. The run that does,
`test/matrix.py` with no flag, is by hand (test/README.md:21). So North Star 1 (accept means
correct) has no gate over the matrix. `error.match_part.clone`, and two guarded-arm shapes found
beside it in row 53, sat broken on main because of this.

Row 53's full run (16,239 programs, 6,374 s) found a second case: 26 programs failed because
`test/matrix.py` still writes `replace(!p, v)` and `c.replace(v)` (109 places on main). Those
were renamed `swap` around 2026-10-20 (CHANGELOG, "Renamed, by hand"). Worse, the `replace`
cells that are meant to be rejected now "pass" only because `replace` is an unknown name. The
first job of this row is that rename. Then it checks that each rejected cell is rejected for
its intended reason.

## Measured (Mac, 2026-11-01, under load)

- A cold full run builds about 180 programs a minute at `-j 6`: about 90 minutes for 16,239.
- A build store costs about 7 MB a program (15 GB after 2,122), so a full run needs about
  115 GB. The shared `.git/rig-build-store` has no cap and was 254 GB when the disk filled.
- A program that's already cached costs one `rig emit`: 5 ms median. All 16,239 together
  take about 80 s of CPU, about 15 s across the suite's workers.
- An emitted package is about 1 KB of the program's own Zig, plus about 1 MB of runtime files
  copied unchanged (`rig/runtime.zig`, `sched.zig`, `tasks.zig`, `alloc.zig`, ...).
  matrix.py's results key hashes all of it, with `src/main.zig`. Over the last 30 days
  `src/runtime.zig` changed in 180 commits on main and `src/main.zig` in 66, and each change
  makes every key stale.

## The design: two tiers

**1. In every `swarm all`: build only what emits differently.**
- A new suite job, `matrix.run`, runs `matrix.py --delta`, split into shards
  (`--shard I/N`) so the suite's workers share it.
- Its results key covers the program's own emitted modules and the verdict code. It leaves
  out the runtime files and the driver. Those are tested by `zig build test`, the suite, and
  tier 2.
- An emit-identical PR then builds nothing and adds about 15 s. A PR like row 53 builds
  only the cells whose Zig changed.
- It builds with no store (`RIG_BUILD_STORE=`): each program's output is removed when it
  passes, so the run can't fill a disk.
- The results cache is empty files, a few MB in all.

**2. Nightly on pup, beside Trig's full suites: the full matrix with today's strict key**
(runtime and driver included), sharded across pup's cores, also with no store. It catches
anything a runtime or driver change broke that tier 1's looser key let through. Its result goes
to `/zfs/trig-pup/full/LATEST` with the rest.

**Beside it:**
- **A known case names what it waits for.** `known: "zig"` (or a text the failure must
  contain) passes only while the case fails that way. A `rig` rejection no longer counts as
  the Zig bug it documents, as happened with the simd case.
- **The build store gets a cap,** trimmed least-recently-used, the way `RIG_CACHE_MAX_GB`
  trims `~/.cache/rig`.

## Decisions (defaults)

1. Add tier 1 (`matrix.run`, `--delta`, emitted modules only, no store) to `swarm all`.
   Default: yes.
2. Add tier 2, the nightly full matrix on pup. Default: yes.
3. `known:` names the failure it waits for; audit today's `known: true` cases. Default: yes.
4. Cap `.git/rig-build-store`, LRU trim, at 40 GB. Default: yes.
5. Build it as one tests-and-tools row, queued with Swiss after row 53. Default: yes.

## Outcome

The owner approved the five defaults, and then, on 2026-11-02, ruled out every scheduled run: no
crons and no nightlies, with full suites only before major and minor releases. Tier 2 was dropped
before #878 merged. Tier 1 runs in `swarm test/rig.rip all`, and builds the changed programs in
packs of up to 400 with `rig batch build`: a cold shard of 398 programs takes 13 s, against
3 min 17 s built one at a time.
