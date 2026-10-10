# Ideas for Rig

Suggestions for making Rig clearer, more complete, and a strong platform
for writing code with AI agents. They come from:

- two blind reviews of 40 Rig programs, by reviewers who had never seen Rig;
- writing part of Quake's `pak.rs` in Rig;
- the soundness work on the compiler.

**Status:** **new** = not yet discussed; **decided** = approved and queued
or in progress; **roadmap** = already in docs/ROADMAP.md.

---

## 0. The bar: beautiful and succinct, or why use Rig?

Safety alone doesn't beat Rust; Rust is already safe. Rig wins only if
the same program is **shorter and plainer** than idiomatic Rust, with
every effect still visible. Measured against `pak.rs`, Rig drops the
noise (`}` lines, `&`, `Some`, `Arc::new`, attributes) but loses
function by function wherever Rust uses iterators. That has to flip.

### 0.1 The target: `pak.rs`'s core, as Rig should read *(new)*
```rig fragment
struct Pak
  name: String
  entries: Vec[PakEntry]
  next: (*Pak)?

  fun find(?self, name: String) -> (?PakEntry)?
    self.entries.find(|e| e.name == name)

  fun over(<self, rest: Pak) -> Pak
    self.next = *<rest
    <self

  fun read_file(?self, name: String) -> Vec[U8]?!
    for p in self.path()
      if p.read_own(name)! as bytes
        return bytes
    none
```
The Rust is `self.entries.iter().find(|e| e.name == name)`,
`self.next = Some(Arc::new(rest)); self`, and
`if let Some(bytes) = element.read_own(name)? { return Ok(Some(bytes)); } … Ok(None)`.
Each Rig function is as short as the Rust or shorter, has no `&`,
`iter()`, `Some`, `Ok` or `Arc::new`, and still shows the move (`<rest`),
the shared allocation (`*`), and the failure exit (`!`).

Getting there takes three changes: §0.2, §0.3 and §1.3.

### 0.2 Iterator helpers in std *(new, high priority)*
`find`, `any`, `all`, `position`, `count`, `map`, `filter`, `sum`, `min`
and `max` on slices and Vecs, each taking a closure that is not stored
(`|e| …`, no `*`).
- `find` returns `(?T)?`, a view of the element with no lifetime written.
  That is Rust's `Option<&T>` without the `&` or the `'a`, and it is
  where Rig's inferred views look best.
- `map` and `filter` build a new `Vec`, so the allocation is visible in
  the type that comes back.

### 0.3 `for` over an iterator *(decided)*
`for x in it`, where `it` has `next(!self) -> T?`, is the desugaring
`while (!it).next() as x`, stated in INTERNALS ("Loops over an
iterator") and SPEC §6 (`for`). A source made there is held in a hidden
binding for the loop, and `<it` moves a place into one. The checker
walks exactly the desugared form, so ownership is unchanged.

### 0.4 Measure it: a Rust-parity corpus *(new)*
"Shorter than Rust" should be a claim the suite checks, like everything
else Rig says.
- Port 10 to 20 small, idiomatic Rust files: `pak.rs`, a tokenizer, an
  LRU cache, a JSON reader, a CLI argument parser, a BST, a ring buffer.
- Keep each Rust original beside its port.
- A suite check reports lines and tokens for each pair, and fails if a
  port grows past its Rust.
- When Rig loses on a file, that is the next language or std item to
  fix. `pak.rs` already points at §0.2, §0.3 and §1.3.

---

## 1. Language: small, high-value fixes

These came out of writing real code (the `pak.rs` sketch) and are each a
small round.

### 1.1 `for e in ?v` should give views of the elements *(new)*
In `for e in ?self.entries`, `e` is a **copy** when the element type
copies, such as a struct of Strings and integers. So this is rejected:
```rig fragment
fun find(?self, name: String) -> (?PakEntry)?
  for e in ?self.entries
    return ?e if e.name == name     # error: `e` is local to this function
  none
```
and the code has to fall back to an index loop. The reader wrote `?` and
expects views.

**Idea:** a written `?` (or `!`) on the loop source means each `e` is a
view (`?T` / `!T`) of the element, whatever the type. A bare `for e in v`
keeps copying. This follows "a written sigil means what it says": a
written `!` must lend to write.

### 1.2 Combined type sigils need parentheses *(new)*
`?T?` means `?(T?)`, a view of an optional. Most readers, the reviewer
included, expect `(?T)?`, an optional view. The compiler's hint already
tells you to add the parentheses.

**Idea:** reject a prefix and a postfix type sigil on the same type unless
it is parenthesized, so it is always `?(T?)` or `(?T)?`. Both readings
stay one keystroke away, and neither one is ever a guess.

### 1.3 A moved-in parameter is the callee's own value *(new)*
`fun over(<self, rest: Pak)` takes `self` by move, but `self` cannot be
assigned, so the body has to rebind it:
```rig fragment
fun over(<self, rest: Pak) -> Pak
  p = <self
  p.next = *<rest
  <p
```
Nothing else can see a moved-in value, so writing it is safe.

**Idea:** a `<` parameter is writable, like a local, giving
`self.next = *<rest` then `<self`. Rust's `mut self` does the same. Read
and write parameters stay as they are.

### 1.4 Error values that carry data *(roadmap)*
`QError::Invalid(String)` has no Rig equivalent, because an error is only
a name. Real programs need context such as `PakError.too_many(count: Int)`.
The design must keep failure visible (`T!`, `e!`) and say who owns the
payload.

### 1.5 Walking a chain *(new, small)*
Walking `next: (*Pak)?` takes a `while true` plus an `if … as … else return`.
With §0.3, a `path()` iterator written once makes every walk a `for`.
Adopt that, rather than new loop syntax.

---

## 2. Syntax consistency *(decided)*

These are decided:

- A statement `<x` drops; `-` only negates.
- Swift-style spacing: a sigil touches what it marks, operators are
  spaced evenly, and `.` has no spaces.
- A multi-line closure ends with `)` on its own line.
- A lend of a place is never the base of a path: `p.x = 4`, not `(!p).x = 4`.
- A write call used as a value puts the `!` in parentheses:
  `if (!set).insert(k)`.
- A slice passed as an argument is read implicitly: `total(w[1..3])`.
- The `?`/`!` symmetry table goes on page one of the docs.

**One more idea in the same spirit (new):** list every place where a
sigil is *optional* (a read lend of an argument, a `?` receiver). Decide
for each whether "optional" stays, and state the full list in one place
in SPEC. The reviewers' second-biggest confusion was "when is a sigil
required?"

---

## 3. Standard library

- **`std.fs`** *(roadmap)*: open, read, seek, read a whole file, list a
  directory, create and remove for tests. **Make porting `pak.rs` its
  acceptance test.** It is about 550 lines, has a ready-made test suite,
  and shows Rig's best ideas: no lifetimes, every effect visible.
- **Assertions in `test` blocks** *(roadmap)*: `expect(a == b)` with
  both values printed when it fails. Without them, ported test suites
  roughly double in length.
- **Text building** *(roadmap)*: join, replace, upper-case copy.
- **A JSON reader and writer** *(new)*: the most common thing real
  programs and agents need, and a good test of owned and viewed strings.

---

## 4. Tooling for the agentic age

The blind reviewers agreed that Rig's best case is "code an agent writes
and a human can review quickly". These make that real:

- **`rig check --json` with machine-applicable fixes** *(TODO.md)*.
  Diagnostics already say "write `rd(?n)`"; give the edit as data
  (file, span, replacement).
- **Apply-every-hint as a permanent suite check** *(new)*: for every
  reject test, apply the suggested fix and confirm it compiles. A
  one-off version of this check caught hints that suggested rejected
  code.
- **A one-page sigil spec for prompts** *(TODO.md)*: generated from
  docs/CORE.md, and checked by the suite like every other doc.
- **`rig effects` for diffs** *(new, distinctive)*: given a diff or a
  PR, list each new move, write lend, clone, drop, shared allocation and
  failure exit, by function. A reviewer reads the effects summary first,
  then the code. No other language can offer this so cheaply, because
  Rig already records every sigil as a named fact.
- **`rig explain <error>`** *(TODO.md)*: the rule behind a diagnostic,
  with one wrong and one right example taken from the docs.
- **A formatter** *(TODO.md)*, so a diff is never about layout.
- **A language server with inlay hints** *(roadmap)*: show the implicit
  read lends, the copies and the drop points that Rig leaves unwritten.
- **An idiomatic example corpus** *(new)*: 30 to 50 everyday programs
  (CLI tools, parsers, a `.pak` reader, data structures, a small
  server). It is the first thing a person or a model sees, instead of
  the compiler's edge-case tests. It also serves as few-shot material
  for models, which have no Rig training data.

---

## 5. Compiler and process

- **One decider, stage 3** *(decided)*: every rule reads the recorded
  fact about what an expression is, never its written form. This is the
  structural fix for the recurring "the same thing inside a wrapper
  slips past" class (`(<(!x))`, closures, `catch`, `??`).
- **A wrapper axis in the program matrix** *(new)*: every form ×
  {parens, `<`, `+`, `catch`, `??`, `e!`, `e?`, block value, closure
  body, `fun` last line}. Each recent soundness hole was one of these
  cells.
- **Check the facts only in debug and test builds** *(decided)*, so the
  one-decider checks stop costing release-build compile time.

---

## 6. Longer term *(roadmap)*

- **Traits or bounds,** so `max[T]` says it needs ordering, and errors
  point at the definition, not the use.
- **Concurrency:** structured tasks, an atomically counted `*T`, and
  rules for what may cross threads.
- **C interop** (`extern` types), needed for SDL, OpenGL and audio.
- **Freestanding code and a teaching kernel.**
- **A north-star dogfood:** a Quake port. It needs C interop, float and
  math-heavy code, and performance, and it would show whether the
  sigils stay readable across 50,000 lines. Start with `pak.rs` (§3),
  then the file system, then the rest.
