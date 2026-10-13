# To do

Work that is decided but not started. Where Rig stands, and the work in
progress, is in [HANDOFF.md](HANDOFF.md).

## After v0.3.0's in-flight work

The in-flight list is in HANDOFF.md, "What comes next". Decided, not
started:

- SIMD: `pad:` reads and `blocks(N)`.
- A String API for part-word appends and windowed writes.
- Multiple results.
- A frame-size guard for every function.
- Switching to Nexus's `Span.text`.

## Agent tooling

- `rig check --json`, with machine-applicable fixes. Many diagnostics
  already name the fix, such as "write `rd(?n)`"; the JSON gives each
  fix as an edit to apply.
- A formatter that writes the canonical style.
- Later, `rig explain` and a language server.
