# Writing a Learn Rig journey

The journeys in [docs/learn/](../learn/README.md) teach Rig one big idea
per chapter. This page is the brief every journey is written from: the
house style, how a chapter is checked, and the outlines of those still
to write.

## What a journey is

A journey is one chapter of 1,500 to 3,000 words, code included, that
brings a reader to understand one idea. Sentences run about 15 words,
sections 100 to 300. There are no em dashes and no hype, and the prose
is timeless: no dates, no "currently", "now", or "new".

1. **The title names what the reader gets** ("Concurrency without
   async"), not the feature.
2. **It opens on a problem the reader already has,** in a language they
   know, in a paragraph or two; that code goes in its own fence
   (```` ```python ````, ```` ```rust ````), which the suite skips.
3. **Code comes before explanation.** A lead-in ends in a colon, a whole
   program follows, then a paragraph names each new mark in order.
4. **Every claim is a checked block.** A program that runs is
   ```` ```rig ```` followed by ```` ```output ```` with exactly what it
   prints. A rule is followed by the program that breaks it,
   ```` ```rig reject ```` and its ```` ```error ```` lines. A program the
   suite cannot run (a server, one that reads input) is
   ```` ```rig ```` alone, checked only. ```` ```rig fragment ```` is
   parsed only; use it sparingly. What the runner cannot check (a
   `rig test` report, emitted Zig) goes in ```` ```text ```` or
   ```` ```zig ````, copied from a real run.
5. **Each sigil or word arrives when a program needs it,** never in a
   list first.
6. **It ends with** a summary (a table, and one rule in bold), a short
   "What is not there yet" where that is honest, and "Where to go
   next": the next journey, then the reference sections. SPEC is the
   last link, never the first stop.
7. **One vocabulary:** lend, view, loan; owner, handle, box; self, never
   "receiver"; task. `&` is the dispatch sigil and `>` the wait sigil.
   The named sets of methods a type provides are APIs
   ([design/apis.md](../design/apis.md)).

Teach only what is built. A planned rule is mentioned under "What is
not there yet", with a link to its design record, never shown as if it
ran. Removed forms are never taught: deadlines are `time.within`, a set
is waited for with `>ts`, and two tasks of different types with
`task.all`.

## Checking a chapter

`swarm test/rig.rip doc-learn-NN-name -q` checks every block of
docs/learn/NN-name.md. Then `swarm test/rig.rip oracle -q`: a doc
example the reference checker rejects is listed in
`test/oracle/rejections` as `doc/learn-NN-name/<hash> <function>`, one
at a time as the run names them. Run one area at a time while writing.
Check each claim against `bin/rig` and `std/` before writing it; a
chapter that finds a compiler problem says so in its PR, and the
problem goes to [backlog.md](backlog.md).

A new chapter is linked from [docs/learn/README.md](../learn/README.md),
from the journey before it, and from the docs map's question table in
[docs/README.md](../README.md).

## The journeys still to write

**07. Generics and compile time.** What a generic body may do with a
`T`, written for the generics Rig has.
- Opens on the largest item of a list, a function every reader has
  written: C's macro or copy per type, Go's old `interface{}`, C++
  templates' page of errors, Rust's `T: PartialOrd + Copy`.
- Sections: one body for many types (`max[T]`, inferred and explicit);
  what the compiler makes (`rig emit`: one instance per type, no
  run-time cost); values known when compiling (`[n: Int]`, `Ring[T, n]`);
  what a body may do with a `T` and how each instance is checked, with
  the error at the call and a note at the body; calling a `T`'s methods
  (APIs Stage 1), the result typed from where the call stands; `reduce`
  over a `[]T`, once std has it; many kinds in one list today, an enum
  with payloads or an object of `*fun` fields.
- What is not there yet: bounds (`[K: Hash]`), APIs of a program's own,
  and API objects (`?{Shape}`), each a stage of
  [design/apis.md](../design/apis.md). Rewrite the chapter's later
  sections as each stage lands.
- Mine: SPEC "Generic types", "Generic functions", "Generic bodies";
  DESIGN "Per-instance checking"; WELCOME's generics table;
  design/apis.md Stage 1; design/simd.md for `Simd[T, n]`.

**11. A real program, end to end.** What a whole Rig program looks like,
from the first file to a tested concurrent service. Written last.
- Outline: modules and directory modules; errors at the boundaries; an
  actor for shared state; an HTTP front; seeded tests; a benchmark; a
  release build.
- Examples: a small service in several files, the launch post's rooms
  server grown up, its modules as ```` ```rig file=m.rig ```` blocks.
- Mine: docs/launch/examples/, SPEC §14, examples/, journeys 03, 04, 06
  and 08.
