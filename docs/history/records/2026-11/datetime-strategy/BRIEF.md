# Panel brief: making an `Instant` from a Unix time

Rig is a language that compiles to Zig 0.17. Its North Star: **a program the
compiler accepts is correct**, and **effects stay visible**: a call that can
fail returns `T!` and is written with `!` at the call (`x = f()!`), or handled
with `catch` or `?? fallback`. A panic stops the program. The owner asks for the
design with the **least surprise** (POLS), and finds a panic on bad input
"violent": he asks why this isn't simply fallible.

Read only: the repo is `~/Data/Code/rig` (main e38454865). Read `AGENTS.md`,
then `docs/design/datetime.md` §5.1, §5.2 (duration forms), §7.1, §7.2 (what
fails and what panics), §7.8 (instants), and `std/datetime/instant.rig`. Jiff
1.0.0's source is at `~/Data/Code/rig/misc/jiff/` (`src/timestamp.rs`). You may
run programs with `~/Data/Code/rig/bin/rig run FILE` (a build of main). Don't
edit, commit or push.

## Today

- `time.Duration` is one `Int` of nanoseconds: ±292 years, so 1677 to 2262
  from 1970. `datetime.Instant` covers the years -9999 to 9999.
- `Instant.from_unix(<duration form>) -> Instant`, no `!` (the owner removed it
  yesterday because it can never fail): a bare `Int` or `Float` of seconds, or
  one or more unit keywords, `ms: t`, `us:`, `ns:`, `seconds:`, ... A duration
  form given a number that isn't constant and is not finite or too big for a
  `Duration` **panics** (§5.2, §7.2); a constant one is a compile error.
- So: a Unix time read from a file or a network message, past about 9.2e9
  seconds (year 2262) or a NaN, panics; and nothing can make an instant past
  2262 from a Unix number at all. `i.unix() -> Duration` saturates outside
  1677 to 2262; `i.unix_s() -> Int` is floored whole seconds, exact at any
  instant, with no inverse.
- A pending owner decision may make a defaulted parameter other than the first
  name-only (`f(1, ns: 5)`, not `f(1, 5)`): fit your signatures to it.

## Questions

1. Should making an `Instant` from a Unix number be fallible? With what
   signature(s), names, and failure modes? Weigh a duration form (`from_unix(x)`,
   `from_unix(ms: t)`) against per-unit makers taking an `Int`
   (`from_unix_s(s, ns: 0)`, `from_unix_ms(ms)`, ...), and whether a `Float` of
   seconds belongs here at all (it resolves only about 240 ns near 1.7e9).
2. The general rule: duration forms panic on a non-constant out-of-range
   number. Is that right for `sleep`, `add`, `time.duration(...)`, or should
   untrusted numbers have a fallible path there too (and what would it look
   like without making every call `!`)? Keep this short; the owner's question
   is about `from_unix`.
3. Your final recommendation: the exact API (names, signatures, `!` or not),
   what each does at the edges (2262, 9999, NaN, negative, `Int.max`), and one
   line of docs for each. Least surprise for a newcomer from Rust, Go, Swift,
   Python, JavaScript or Java.

Cite precedent with care (and check it in source where you can): Rust's
`Duration::from_secs_f64` (panics) and `try_from_secs_f64`; Jiff's
`Timestamp::from_second`, `from_millisecond`, `from_duration`; chrono's
`DateTime::from_timestamp`; Go's `time.Unix`, `UnixMilli`; Zig's error unions;
Swift's `Date(timeIntervalSince1970:)`; Java's `Instant.ofEpochSecond`; Python's
`datetime.fromtimestamp`; JavaScript's `new Date(ms)` and Temporal's
`Instant.fromEpochMilliseconds`; Kotlin's `Instant.fromEpochSeconds`.

Write your full report to your file in
`/private/tmp/claude-501/-Users-shreeve-Data-Code-undat/6fff74ce-077f-4bc9-afce-9c419f622ac3/scratchpad/unix/`
(name given in your prompt). Return a summary of at most 400 words: your
answers to 1 to 3, the recommended API in a short code block.
