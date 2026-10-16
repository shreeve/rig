# Rig notes: what making std.json fast found in the language

A running list of the weak, missing, and inconsistent spots in Rig that
work on `std.json` runs into, written down so they can be fixed while
the language is young. Each entry says what is wrong or missing, where
it showed up, what it costs, and a fix to consider.

**Status** is one of:
- *verified*: a program or a measurement shows it;
- *observed*: seen in code or emitted output, not yet reduced to a test;
- *in flight*: a round is fixing it;
- *parked*: real, but not worth the change now;
- *fixed*: on `main`.

The measurements are in [json/RESULTS.md](json/RESULTS.md), and the
tools that take them in `bench/json/`.

## Asymmetries and inconsistencies

1. **Vectors take every operator but the shifts.** `+ - * & | ^ +% -%`
   and the comparisons work lane by lane, but [SPEC](../SPEC.md#vectors)
   says the shifts take no vector. Every nibble lookup needs `v >> 4`,
   and the `\u` hex decoder `v << 4`. Fix: `v >> c` and `v << c` (and
   `<<%`) on integer lanes, with the scalar rules. *In flight (requested
   for SIMD round 2).*
2. **A `match` pattern cannot name a constant.** std.json's `Doc.kind`
   matches its tape tags as bare literals (`0 => .null`, `1, 2 =>
   .bool`), because `T_NULL => .null` is not a pattern, though the same
   names work in every expression. Fix: a constant's name (`Name`,
   `mod.Name`) as a pattern, matched by value. *Observed.*
3. **Proven forms covered some reads and not others.** The proofs round
   gave `at`, `readInt`, and `+` proven forms but not `simdRead`, so the
   one check left in std.json's string scan cost gsoc-2018 9% of its
   instructions and 5.5% of its time. Fix: one proof fact, "these n
   bytes from i are inside s", that every read and write form consumes,
   so a new form cannot miss it. *Fixed (#149).*
4. **A vector could not be a module-level constant.** `WS =
   Table([0x20, 0, ...])` was rejected, though scalar and array
   constants are accepted at module level; every lookup table std.json
   needs (whitespace, UTF-8, hex) is one. *In flight (SIMD round 2, in a
   separate commit for the design owner).*
5. **`~` is the weak sigil, so bitwise not is `x.not()`.** Masks use
   `m.not()` the same way, so it is consistent inside Rig; noted only
   because it surprises C, Rust, and Zig readers. *No change proposed.*

## Missing pieces that cost speed

6. **A compile-time parameter blocks inlining.** `src/inlining.zig`
   never inlines a function with compile-time parameters, so
   specialization, which should cost nothing, costs a call. Two copies
   of `document` (`document[dense: Bool]`) left `skip_ws[dense]` and
   even `scalar` out of line: 10-15% more instructions on every corpus
   file. Fix: decide inlining per instance, after instantiation. *In
   flight (#154).* Under #154 the same `document` still lost
   `Doc.number`'s inlining (canada 10% slower): its cap on inlined calls
   per function counts a generic's calls in every branch, those a
   compile-time constant removes too, and then out-lines the callee
   that brings the most calls, the hottest. Fix: drop the cap, which
   no longer guards correctness, or count per instance after folding
   and out-line the coldest callee. With the cap removed, `Doc.number`
   was still out of line: Rig emits std.json's large functions
   (`document`, `scalar`, `number`, `escaped`) as plain functions, and
   LLVM inlines `scalar` and `number` only because each has one call
   site. Two instances of `document` give `number` two, and LLVM leaves
   it out. Fix: Rig emits as `inline` a function with one call site per
   instance, whatever its size, so Rig decides it and a specialization
   keeps it. *Verified; proposed to the Rig session.*
7. **No way to keep a cold path out of line.** The whitespace bitmap's
   run function, called only for deeply indented documents, was inlined
   at every call site and cost 4-6% more instructions where it never ran.
   The only way to keep it out today is to give it a compile-time
   parameter, which works only because of entry 6. Entry 6's fix likely
   removes this case: with a `document` specialized per input, the
   scalar copy holds no bitmap code at all. The preferred fix after that
   is for the compiler to infer coldness, as it decides inlining: a
   function reached only on a failing path (std.json's `fail`, a panic,
   a branch that returns an error) is emitted cold and out of line
   (`@branchHint(.cold)` in Zig), with no new syntax. A marker such as
   `cold fun` is a design owner's decision, since inlining has no
   syntax, and comes back to the owner only if cases remain that
   inference cannot find. The vector UTF-8 check is a second case: its
   block loop, reached only from a string's first non-ASCII byte, was
   inlined through `plain` and `string` into `document`, and took 6-17%
   more instructions on five corpus files, twitterescaped's 17% among
   them, which has no non-ASCII byte at all. std.json keeps it out by
   writing the loop and its fallback as one method too large for the
   inliner (`utf8_text`): size standing in for coldness. A rule by
   structure cannot tell it from a hot function: `Doc.number` also has
   one call site inlined into `document`'s loop, yet per parse it runs
   111,126 times on canada and 14,392 on citm_catalog, while
   `utf8_text` runs for 755 of twitter's 18,099 strings, 108 of
   citm_catalog's 26,604, 2 of github_events' 1,891, and none on the
   other three files. Only the programmer, a marker, or a profile knows
   which is which. A second
   reason surfaced later: a large function with one call site is inlined into its caller by LLVM, so std.json's
   parser is compiled as part of whatever calls `parse`, and its code
   changed with the caller (when the benchmark's `main` was simplified,
   canada took 9% fewer instructions and github_events 10% more,
   docs/json/RESULTS.md).
   Keeping such a function out of line would make its code the same in
   every program. *Verified; waiting on #154 to re-measure.*
8. **A List's length and capacity are reloaded on every push.** In
   `document`, a large function, LLVM keeps the tape's pointer, length,
   and capacity in the stack frame: each `push` loads them and stores the
   length back. On `[[0,0], ...]`, where a number costs nothing,
   std.json spends 204 instructions per value against sonic-rs's 144.
   The cause is `push`'s out-of-line growth, `grow(self: *Self, ..)`:
   passing the List's address means even a List held in a local stays
   in memory, and every element store may change its length. Growing
   by value instead (`buf = grown(buf, want)`, for `List` and `String`;
   branch `growval`, 9786aed83) keeps a local List's fields in
   registers. That wins in a small loop and loses in `document`, so it
   did not land:
   - A loop of 400M pushes to a local `List[Int]` ran 383% faster (0.349
     against 1.685 ns a push), and to a local `String` 423% faster; a
     List in a boxed object's field ran the same.
   - With std.json holding the tape in a local in `document`, growval
     cost 3.9% more cycles on twitter and 4.9% more on citm_catalog,
     while retiring fewer instructions. LLVM inlined nearly every push
     (`document` grew from 15.0 to 15.9 KB) and kept the tape's three
     fields live across a function full of calls, paying in moves and
     spills; with the List's address taken, the tape stays on the stack,
     where store-to-load forwarding is cheap.
   - Not layout: moving `document` by 0-32 bytes, without and with
     growval, spans 1.771-1.809M and 1.877-1.956M cycles per citm parse,
     ranges that do not overlap.
   - The parts, citm and twitter cycles: by-value growth alone 6.0% and
     2.3% more; laying a List out pointer, length, capacity alone 2.1%
     and 1.3% fewer; a `@branchHint(.cold)` growth branch 5.5% and 3.2%
     more.
   - The field order matters only with by-value growth: LLVM then loads
     the adjacent pointer and capacity as one `ldp`, which waits on the
     loop's stores on Apple cores (6.0 against 2.3 cycles a push to a
     field); `ptr, len, cap` keeps them apart.

   Until then std.json holds the tape in a local in `document` (`replace`
   it out, push, put it back), its fastest form with the runtime as it
   is. Fix to consider: a List write window the program chooses, reserve
   n and write through a cursor kept in a register, as
   `!t.push(v, keep: k)` does for `String`, so registers are spent only
   where the program asks. A `noalias` round should expect the same
   trade-off: freeing registers can lose in a large function, so judge it
   on `document`'s wall time, not on a micro-benchmark.
   *Verified (measured); parked for a write window.*
9. **Results through memory.** `take_digits` returns the position and
   hands the digits' value back through `m: !U64`, which stays in a
   register only when the call is inlined; a whitespace cache cannot
   stay in `document`'s registers across `key` for the same reason.
   Several results now exist (`-> (Int, U64)`), but Zig returns them
   through memory, as it does an object. Fix: small results in
   registers (TODO.md). *Observed.*
10. **Proofs stop at a call.** `skip_space(src, i)` always returns a
    value at least `i`, but `document`'s next `src[i]` still tests
    `i >= 0`, since the fact does not cross the call. Fix: facts a
    function proves of its result, or proofs after inlining.
    *Observed. Partly fixed: a function whose every return value is a
    small literal, or an object whose field is one, proves a caller's
    `i += d.size` (docs/INTERNALS.md, "Proven checks", Results); a bound
    in terms of an argument, such as `>= i`, is still open.*
11. **A List's length converts to `Int` with a check.** `rig.len` tests
    `n > max_len` at every `xs.len` (about 11 sites in std.json), though
    no length can exceed `Int`. Fix: let the runtime assume it. Measured
    small: 0.5-2% of instructions. *Verified.*
12. **No compile-time choice by target.** std.json has not needed one:
    the whitespace bitmap turned out to depend on the input (dense
    whitespace), not the CPU, so a choice per input fits. Still worth
    having for code that depends on the target. Fix: conditional
    compilation on os, arch, and CPU features (on the roadmap).
    *Built for the arch: `use std.target`, then
    `TIER = 0 if target.arch == .x86_64 else 16`, a choice Zig makes
    per target (SPEC, "The target"). std.json measured its vector string
    scan from the first byte (`TIER = 0`) 6% faster by geomean on x86_64
    (exclusive timing on pup, 2026-10-13), and 5-9% slower on three files
    on the Mac, which keeps 16; it moves to `target.arch` once this
    lands. The os and CPU features are still open.*
13. **No String write window.** Copying the text between escapes 16
    bytes at a time needs "store a block, keep k bytes". *Fixed (#150,
    `!t.push(v, keep: k)`).*
14. **SIMD round 2:** a byte lookup, saturating add and subtract, and a
    joined shift (the design owner approved `table.lookup(v)`, `+|` and
    `-|`, and `cur.lag[k](prev)`). They make UTF-8 checking (twitter
    6-7% faster in the opcode study), the `\u` decoder, and a lookup
    whitespace classify possible. *Fixed (#156).* std.json checks
    UTF-8 with them: twitter and github_events 9% faster on the Mac.

15. **A String made from known text is over-allocated.** `String(text)`
    reserves about half its length again plus 128 bytes (Zig's growth
    rule), though nothing may ever be appended. Memory aside, the
    sanitizing allocator's guard page then lies past that capacity, not
    past the text, so it cannot catch a read just past the end; only the
    bounds checks do (std.json's tests copy each input this way). Fix:
    allocate a `String` made from text, or `String.with_capacity(n)`, to
    exactly its size. *Verified (a reviewer's probe: `String("abc")` had a
    capacity of 132, and reads at indexes 3 to 131 did not fault).*

27. **A short formatted String is spread over a large allocation, which
    slows every read of many of them.** `String("key", i)` builds its
    text through an `std.Io.Writer.Allocating`, which leaves a 10-byte
    String with 134 bytes of capacity; entry 15's rule, met through
    formatting. A million such keys each sit in their own large block,
    so a pass that reads their bytes misses the cache on each: hashing
    them (`k.hash()`, Wyhash) took 5.3-8.7 ms where the same keys
    allocated exactly took 1.6-1.9 ms, about 4 times as long, in a Zig
    probe that built them both ways (and 6-9 ms in Rig). It shows in
    `bench/hash`: a `Map[String, V]` lookup measured against Zig's
    `StringHashMap` over exactly sized keys is 21-30% slower, and
    faster or within 10% once Zig's keys are built the way Rig's are.
    Fix: as entry 15's, size a String made by `String(...)` to its text
    (shrink once formatting is done, or format into an exact buffer).
    *Verified (bench/hash, and the probe above, on the Mac under load).*

## Missing pieces that cost clarity

16. **No character literals.** std.json names 19 byte constants
    (`QUOTE`, `BACKSLASH`, `LBRACE`, ...) and writes `match` arms in hex.
    Fix: `'"'`, `'\\'`, `'{'` as `U8` values. *Observed.*
17. **An enum variant's name is not text.** `error_name` spells out all
    13 `Error` variants in a `match`. `print` shows a variant as `.ok`,
    and `@variants(T)` lists the values, but no expression gives the
    name as text. Fix: `e.name()`, a `Static`. *Observed.*
18. **Errors carry no data.** `parse` returns a `Bool` and keeps `error`
    and `error_pos` in the `Doc`; the parser's internal steps return
    `-1`. Fix: errors with a payload (an offset), so `parse` can be `!`.
    std.json's final API waits on it. *Observed.*
19. **Long literals and embedding.** A string literal was at most 64 KB
    and a source file is 16 MiB, so the benchmark and the tests split
    each JSON file into 60 KB literals and join them at run time. Fix:
    `@embed("file.json")` as a `Static`, or longer literals. Literals
    of any length within the 16 MiB source are *fixed* (`@longtokens`);
    `@embed` is *observed*.

## Traps

20. **Proofs ignore early-return guards.** After `return 0 if i < 0 or
    i >= s.len`, `s[i]` is still checked; only the enclosing form, `if
    i >= 0 and i < s.len` then `return s[i]`, is proven: two spellings
    of one fact, treated differently. In std.json it costs nothing
    measurable (LLVM removes the check once the helper is inlined), so
    the case is clarity, not speed. *Parked (its round is saved on a
    branch).*
21. **A profiler's "check" includes the access.** Samples whose
    innermost frame is `rig.at` or `index` count the load as well as its
    bounds check, so they overstate what checks cost (canada: 5% of
    samples, 0% of instructions when removed). Size a check by removing
    it and counting (`bench/json/checks/sizing.py`). *Verified.*
22. **On Apple silicon, a hot loop's layout moves its time by 5-7%.** A
    variant that ran the same instructions as `main` on twitter,
    gsoc-2018, and github_events (within 1-2%) was 5-7% slower on them,
    because code added elsewhere in `document` moved its loop. Only
    interleaved timing can judge a change to a hot loop. Specialization
    without lost inlining (entry 6) lets a fast path stay unchanged.
    *Verified.*
23. **Wrapping arithmetic is slower than proven arithmetic.** Writing
    `+%` to avoid an overflow check *adds* 1-2.5% of instructions: a
    checked add leaves LLVM the fact that it did not overflow, and `+%`
    loses it. Fix: say so in SPEC beside `+%`, and let proofs cover the
    checks people would otherwise wrap away. *Verified.*
24. **macOS's instruction count needs a median.** One binary's
    `/usr/bin/time -l` instruction count varies by several percent from
    run to run, so the least of 3 picks outliers. Tooling, not language.
    *Fixed (#144: the median of 5).*
25. **Fewer instructions can be slower.** A whitespace skip that read 16
    bytes and found the first non-whitespace lane (`WS.lookup(v & 0x0F)
    == v`, then `.not().first()`) retired 12-29% fewer instructions on
    four corpus files and was 32-41% slower on the Mac. On x86 its IPC
    fell from about 5 to 3.7, for 9-13% more cycles on three of those
    files. The byte loop it replaced is branchy, so the
    predictor guesses where a run ends and the next token starts early.
    The vector form makes that position a data dependency (load,
    classify, move the mask to a register, count) on every token's
    critical path. A second case keeps the count in a general register:
    after a whitespace byte, measuring the run of spaces that follows
    from one U64 (`(w ^ SPACES).trailing_zeros() >> 3`, branch-free) took
    13-18% fewer instructions on twitter, citm_catalog and github_events
    and was 13-34% slower on them. A position computed from data waits
    for its load; a branch the predictor learns does not.
    `bench/json/guard.py` counts instructions only, so it passes such a
    change: a change to a hot loop is judged by time on both machines.
    *Verified* (docs/json/RESULTS.md).
26. **A guard cannot bind.** `return i + k if m.first() as k` is
    rejected with "use of unbound name `k`": a guard (`if cond` after a
    statement) takes a `Bool`, and `as` binds only in a block form (`if
    m.first() as k` then `return i + k`). Either the guard should bind,
    as `if … as` does, or the error should say that a guard cannot
    bind. *Observed.*
