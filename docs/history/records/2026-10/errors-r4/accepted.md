# R4 (#565): a placement swing accepted once (2026-10-22)

std.json's speed rule is that it never gets slower beyond 2% noise, on
either machine. #565 (`JsonError`, and `load` beside the unchanged
`parse`) met it on the Mac. Every file was within 1% of main, safe and
fast, over five interleaved rounds of 15.

On pup (x86, core 6) it did not. Against main with Option U (#566),
fastest of five rounds:

| File | Safe | Fast |
|---|---|---|
| twitter | 2.0% slower | 2.3% slower |
| citm_catalog | 1.3% slower | 6.9% faster |
| github_events | 0.6% faster | 6.7% faster |

Every other file and build was within 2%, most within 1.5%.

**The cause is placement, not work.** Measured by the fork, with one
compiler building main's json.rig and #565's:

- Every hot function (`document`, `escaped`, `skip_plain_ascii`) sits
  exactly 32 bytes later on pup, in all four builds, because a little
  code is placed earlier in the binary. citm's fast `document`, for
  one, moves from 0x11e1b00, a 256-byte boundary, to 0x11e1b20. On the
  Mac the addresses are identical.
- The instructions are the same code, and slightly fewer of them: twitter
  safe 1,101.3M → 1,100.4M, fast 1,033.3M → 1,031.4M.
- The swing goes both ways (twitter slower, citm and github_events
  faster): one 32-byte shift against 64-byte lines.

**Decision.** The owner accepted it, for this one change only: "Yes,
seems ok for this one instance", and "So that we can move forward".
It is not a standing rule; every other change still meets the 2% line.

**Follow-up.** The consolidation round's speed track aligns std.json's
hot functions, so a shift elsewhere cannot move them. The speed census
watches twitter on pup until then.
