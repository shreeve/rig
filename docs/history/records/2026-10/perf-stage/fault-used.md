# Faulting in only what a large List uses (2026-11-01)

**Correction ([slack-sources.md](slack-sources.md)):** row 43's 14.2 MiB
was mostly a miscount; ts-pattern's large blocks hold 4.3 MiB unwritten at
the peak, most of it faulted in ahead. The RSS measured here stands.

Queue row 45, from row 43 ([large-blocks.md](large-blocks.md)), which
found 14.2 MiB of ts-pattern's large blocks resident but never written
at its heap peak, 18% of their room. Two levers were named: fault in
ahead less of a large block, and grow large Lists by half again rather
than twice. Measured only; nothing was built.

## The arms

Trig `4bc7a9a`'s release package, emitted once by Rig `a32adf178`, then
patched and built by Zig as `rig build --release` builds it (`-Osafe
-fomit-frame-pointer`) on pup's release slots ([arms.sh](fault-used-data/arms.sh)):

| arm | what changes |
|---|---|
| m | main: a new large block faults in its first three quarters ahead, a block grown by `mremap` half the bytes it gains (`likelyFilled`, up to 8 MiB) |
| a | a byte-identical copy of m (A/A) |
| h | a new large block faults in only its first half, what a List's copy writes at once; a grow by `mremap` faults in nothing (its moved pages are resident) |
| z | no large block faults in ahead |
| g | as m, but a List of 32 KiB or more grows by half again, not twice (`growBy`) |

All five print the same on the six projects. Timed on pup with
`time-ab.sh` ([ab.conf](fault-used-data/ab.conf)): one checker on core 6
and four on cores 0, 6, 8 and 10, arms shuffled each round after a
warm-up, 60 rounds on mitt, neverthrow, and superstruct and 20 on zod3,
ts-pattern, and tiny-invariant, the binaries on tmpfs. Medians.

## What they do

Each arm against m: time, cycles (user and kernel), peak RSS, and page
faults.

| project | checkers | m time, RSS | h | z | g |
|---|---|---|---|---|---|
| mitt | 1 | 21.1 ms, 31.2 MB | +1.3% time, +1.5% cycles, −0.5 MB, +818 faults | +3.3%, +2.7%, −0.5 MB, +1,900 | −1.4%, +0.2%, −0.2 MB |
| neverthrow | 1 | 22.9 ms, 30.5 MB | +1.6%, +2.1%, −0.5 MB, +922 | +3.7%, +5.0%, −0.5 MB, +2,296 | −0.5%, +1.1%, +0.2 MB |
| superstruct | 1 | 30.3 ms, 23.3 MB | −0.1%, +0.4%, −0.2 MB | −0.1%, +0.4%, −0.2 MB | +0.1%, +0.4%, −0.2 MB |
| zod3 | 1 | 166.3 ms, 71.8 MB | +0.5%, +0.7%, −1.4 MB, +1,945 | +1.1%, +1.3%, −1.4 MB, +3,612 | −0.4%, +0.4%, −0.2 MB |
| ts-pattern | 1 | 894.4 ms, 224.4 MB | +0.1%, +0.2%, −2.4 MB, +7,024 | +0.0%, +0.2%, −2.4 MB, +10,190 | +0.5%, +0.5%, +1.2 MB |
| tiny-invariant | 1 | 72.5 ms, 46.9 MB | −0.2%, −0.1%, −0.9 MB | +0.5%, +0.9%, −0.9 MB | −0.9%, −0.1%, −0.2 MB |
| zod3 | 4 | 102.4 ms, 102.8 MB | +1.0%, +0.5%, −1.8 MB | +0.7%, +0.7%, −2.1 MB | +0.5%, +0.3%, −0.3 MB |
| ts-pattern | 4 | 361.8 ms, 251.5 MB | −0.7%, −0.9%, −6.0 MB, +6,407 | −0.8%, −0.5%, −6.2 MB, +9,465 | −0.3%, −0.6%, −0.2 MB |

The A/A arm moved time by −1.0 to +0.7% in every row but the small
projects at four checkers (neverthrow +2.5%, superstruct +5.7%, where
every arm moved alike), and cycles by −0.5 to +0.9%. The full table,
with instructions and system time, is from
[ab-small.txt](fault-used-data/ab-small.txt) and
[ab-large.txt](fault-used-data/ab-large.txt).

## What it means

1. **Faulting in less saves little memory.** Faulting in only the half
   a copy writes (h) lowers peak RSS by 0.2 to 2.4 MB at one checker
   (0.7 to 1.9%) and by up to 6.0 MB at four (ts-pattern, 2.4%).
   Faulting in nothing ahead (z) saves no more. So of the 14.2 MiB row
   43 found resident and unwritten on ts-pattern, faulting ahead holds
   about 2.4 MB at one checker. The rest is not measured here; row 43
   names huge pages for blocks of 16 MiB or more, which fault 2 MiB at
   a time, and kept blocks reused, whose pages are resident already.
2. **It costs cycles where Trig is smallest.** On mitt and neverthrow h
   takes 1.5 to 2.1% more cycles and z 2.7 to 5.0%, each from the
   page faults faulting ahead had saved (800 to 2,300 more a run). On
   zod3 h costs 0.7%; on ts-pattern it is level.
3. **Growing large Lists by half again (g) saves nothing measurable:**
   −0.3 to +1.2 MB of peak RSS, for 0.1 to 0.35% more instructions
   from the extra grows. A doubling List's room past its length is not
   what sets Trig's peak.
4. **Nothing clears the bar.** h trades at most 2.4% of peak memory for
   up to 2% of the small projects' cycles, and the owner's rule puts
   Trig's speed first. Row 45 closes as measured.
