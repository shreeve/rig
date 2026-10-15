# To do

Work that is decided but not started. Where Rig stands, and the work in
progress, is in [HANDOFF.md](HANDOFF.md).

## After v0.3.0's in-flight work

The in-flight list is in HANDOFF.md, "What comes next". Decided, not
started:

- SIMD: `pad:` reads and `blocks(N)`.
- A String API for part-word appends and windowed writes.
- Multiple results.
- A generic body's own holding of a `T` (`h = *<x`, `List[*T]`, a call
  passing `<x` to `*T`) at an instance whose `T` is held (`T = ~U`
  makes `*~U`): rejected per instance, with the generic per-instance
  requirements round (option (b)). SPEC "Box" shows it as pending.
- A frame-size guard for every function.
- Switching to Nexus's `Span.text`.
- `text.ByteSet`, a byte set built once when the program runs and
  searched with `set.find(s, at)`: the run-time sibling of
  `text.find_any[set]`. Built when a port needs a set known only at run
  time; none does yet.
- Big integers in the standard library, to replace Trig's own: arbitrary
  precision, enough for JavaScript number and BigInt work (Trig's jsnum
  uses them in 3 places). Trig's version passes all 32,076 of its test
  cases; the std one must pass the same cases and be as fast before Trig
  swaps.

## Agent tooling

- `rig check --json`, with machine-applicable fixes. Many diagnostics
  already name the fix, such as "write `rd(?n)`"; the JSON gives each
  fix as an edit to apply.
- A formatter that writes the canonical style.
- Later, `rig explain` and a language server.
