# Review of PR #935 (rv-std3, head 9ae3a9e1d)

Verdict: the std changes are correct and match the approved list. The
migration tool has two silent meaning changes (one medium, one low-medium)
that should be fixed before Trig gets the script. One doc claim is
inaccurate. The rest are nits.

Probes are in $TMPDIR/r935 (rnd*.rig, big.rig, pw*.rig, js.rig, old*.rig,
mig/a.rig, m2.rig). Main's behavior was checked with
~/Data/Code/rig/bin/rig (8b3549a).

## Approved items: all built as approved
- `json.parse(src: ?String) -> Doc!JsonError` exists (std/json.rig:570).
  The returned Doc is tied to `src`: returning it past a local `s` and
  dropping `s` while it is alive are both rejected. `doc.len` is a
  `pub ?len` field, so assigning it from outside is rejected.
  `int/string/bool/float(i)` work. The 12 `JsonError` variants carry `at`,
  and the offsets match the old ones on 13 inputs. `load` reuse works, and
  `len` is 0 after a failure.
- `compare` is gone for `order`, `equals` is gone, `to_float` exists,
  needles are `?T`, std.iter is gone, `powf` is gone, and BigInt is
  `Eq + Ord + Hash`. Each of these has a rejection hint.
- random.int (Lemire): seven buckets over 700k draws come out within 0.3%
  of each other. The span 3·2^62 is the case where Lemire's method without
  rejection would skew results 2:1 by residue mod 3; it comes out uniform
  (99980/99466/100554). The full Int range never yields `Int.max`. A span
  of 1 at Int.min and at Int.max-1 is correct, and `lo == hi` panics.
- BigInt: `==`, `order`, and Map lookup agree for 0 built eight ways
  (parse "-0", -5·0, 5-5, -5+5, 0<<100, 1>>5, 0^3, "00000") and for 2^64
  built seven ways (shl, shr, sub, mul by -1, parse). The ordering of
  negative numbers is correct.
- Int `math.pow`: overflow panics in debug and wraps under
  `--release=fast`, the same as `*` does. `pow(0, -1)` panics with a
  division by zero. `pow(-2, 63)`, `pow(0, 0)`, and negative powers all
  give the right answers. Mixing an Int and a Float is rejected with a Rig
  diagnostic.
- Suites: doc (953 jobs), doc-STD, std-misc, std-iter, and cli.migrate_std
  are all green.

## Issues
1. **Medium: tools/migrate-std-0.3.py:294 (run, powf) silently changes
   meaning.** `math.powf(2, -1)` becomes `math.pow(2, -1)`, so 0.5 turns
   into 0. `math.powf(2, 3) / 3` turns 2.666… into 2 (probe old1.rig vs
   new1.rig). Under `powf`, Int literals were Floats; under the generic
   `pow` they make T an Int. Fix: rewrite integer literal arguments as
   float literals (`2` → `2.0`). Print MANUAL when an argument is not
   clearly a Float.
2. **Low-medium: migrate-std-0.3.py:556 (iter.sum) silently changes
   meaning.** `iter.sum(!c) ?? 0 + 1` becomes `(!c).sum() + 1`. `??` binds
   looser than `+`, so the original is `sum ?? (0 + 1)`: 10 turns into 11.
   Fix: accept `?? 0` only when what follows is the end of the line, `)`,
   `,`, `]`, `and`, `or`, `if`, or `else`. Print MANUAL otherwise.
3. **Low: docs/STD.md:71 and :118, std/math.rig:45 say a float's pow "is
   C's `pow`".** Only the special cases are C's. The values come from
   Zig's std.math.pow, which differs from libm:
   `pow(1.0000001, 1e9)` gives 2.688103843211962e43 where libm gives
   2.6881038582144647e43 (a relative error of 5.6e-9), and
   `pow(0.999, 12345.6)` is about 500 ULP off. The code itself is not new
   (`powf` used the same function). Fix: reword to "Zig's `std.math.pow`,
   with C's answers for zeros, infinities, and NaN", and record the
   accuracy gap in the backlog.
4. **Low: migrate equals at :500 builds `x == y == false`** from
   `x.equals(y) == false`. That is rejected, not silent. Fix:
   parenthesize when a comparison follows.
   `-text.compare(a,b) < 0` becomes `-a.order(?b) == .less`, which is also
   rejected. Print MANUAL when a unary `-` comes before the call.
5. **Low: the `.equals(`, `.compare(`, `.to_f64(`, and `.get_int(`
   rewrites apply to any receiver** in a file that uses std.bigint or
   std.json. The only guard is that the file does not declare the method,
   and `declares` misses `sub` and generic `fun equals[T](`. A user type
   imported from another module that has its own `equals` and is also
   `Eq` would change meaning without notice. It is rare. Fix: note it in
   the docstring, or print MANUAL when the receiver is not known to be a
   BigInt or Doc.
6. **Nit: the old `JsonError.bad(...)` and `match` arm `.bad(kind, at)` get
   no hint** ("no variant `bad` on enum `json.JsonError`"). Add `bad` to
   `stdRenamed`.
7. **Nit: std/json.rig:176 `load` never clears `@fault`.** Every reachable
   failure records one, so `?? JsonError.unexpected(at: 0)` and a stale
   fault are unreachable today. `@fault = none` at the start would keep a
   future path that returns -1 without recording a fault from reporting
   the previous load's error.
