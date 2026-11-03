# Reader: what makes the library's Rig beautiful, how it is measured, how it is shown

Rig `bin/rig` at main `1b2f4b59d`, 2026-10-29. Every Rig claim below was probed; the probe
files are in `reader-probes/` beside this report. The line counter is `sloc.py` beside it.

## 1. What "beautiful" means here

From the mantras, DESIGN, the examples and the approved style recommendations, the library's
bar is one sentence: **every line says what it does to whom, and says nothing else.** That
splits into five tests a reviewer can apply to any port:

1. **Shorter and plainer than the Rust** (the mantra a new form must clear). Measured, below.
2. **Every effect visible, no sigil spent on nothing.** A move, clone, write, failure, or
   allocation shows where it happens; a plain read stays bare (`size(v)`, not `size(?v)`).
   A sigil the compiler would accept but that changes nothing is noise.
3. **The problem dissolved, not solved.** Where Rust needs machinery to say something
   (lifetimes, `as_deref`, `shift_mut_ref`, `Arc<Mutex<…>>` plus lock calls), the Rig port
   should have nothing in its place, not a shorter version of the machinery.
4. **One word per idea, std's words.** `len` stored, `count` computed, `items()` a read
   walk, verbs for actions, questions for tests (`is_empty`).
5. **Reads top to bottom like the Rust it ports**, so the side-by-side lines up.

## 2. The Rust, read for noise, and Rig's form (probed)

| Rust noise | Where | Rig form | Probe |
|---|---|---|---|
| `self.head.take()` | second.rs push, pop | `<@head` (take leaves `none`) | second.rig |
| `take().map(\|node\| { self.head = node.next; node.elem })` | second.rs pop | `node = (<@head)?.unbox()` / `@head = <node.next` / `<node.elem` | second.rig |
| `as_ref().map(\|node\| &node.elem)`, `Option<&T>` | second.rs peek | `if @head as node` / `return ?node.elem` / `none`, result `(?T)?` | second.rig |
| `Iter<'a, T>`, `as_deref()`, three lifetime annotations | second.rs iter | `fun iter(?@) -> Iter[T] from @`; `obj Iter[T]` with `at: ?^Node[T]?`; no lifetime anywhere | second.rig |
| `impl Drop` loop to avoid recursive drop | second.rs | nothing: the runtime releases deep box chains through its drop queue; a 1,000,000-node stack drops clean under `RIG_SANITIZE=1` | second.rig |
| `IntoIter<T>(List<T>)` wrapper + `impl Iterator` | second.rs | a `Drain[T]` object with `next(!@) -> T? = pop`; loop as `d = <s.drain()` then `for x in !d` | iters.rig |
| `shift_mut_ref`, `mem::replace`, `split_at_mut`, `&mut &'a mut [T]` | nbody advance | index loops: `for j in i + 1..bodies.len` and `bodies[i].vx -= dx * mj`; the helper and its lifetimes vanish. Output -0.16907516382852447 / -0.16908760523460614, matching `1000_out` to 9 places | nbody.rig |
| `Arc<Shared>`, `Mutex<State>`, `.lock().unwrap()` on every method, `drop(state)` before notify | mini-redis db.rs | `*Actor(Store(...))`; `fun get(?@, key: ?String) -> String?` is one line, `+@entries.get(key)?`; tasks share it with `serve(+db, "k1")&`, `>a` | db2.rig |
| `Arc::clone`, `self.db_holder.db()` | server.rs | `+db` | db2.rig |
| `Rc<RefCell<…>>`, `borrow_mut()`, `Ref::map(node.borrow(), …)`, `Rc::try_unwrap(…).ok().unwrap().into_inner().elem` | fourth.rs | the Idiom expert's map (`*Node` with a weak `prev: ~Node[T]?`); not probed here | — |

The Rig for second.rs's library part (push, pop, peek, peek_mut, iter, iterator; my probe):

```rig
obj Node[T]
  elem: T
  next: ^Node[T]?

obj Stack[T]
  head: ^Node[T]? = none

  sub push(!@, elem: T)
    @head = ^Node(elem: <elem, next: <@head)

  fun pop(!@) -> T?
    node = (<@head)?.unbox()
    @head = <node.next
    <node.elem

  fun peek(?@) -> (?T)?
    if @head as node
      return ?node.elem
    none

  fun peek_mut(!@) -> (!T)?
    if !@head as node
      return !node.elem
    none

  fun iter(?@) -> Iter[T] from @
    Iter(at: ?@head)

# A view walking the nodes from the head.
obj Iter[T]
  at: ?^Node[T]?

  fun next(!@) -> (?T)?
    if @at as node
      @at = ?node.next
      return ?node.elem
    none
```

All of second.rs without its tests is 86 code lines and 618 tokens; the Rig with `drain` and a
write walk in place of `iter_mut` is 40 lines and 325 tokens (53% fewer tokens). `iter_mut` is
not equivalent; see finding 1.

### Findings from the probes (for the owner or a backlog row)

1. **No iterative write cursor down owned links.** `at = !@head` then `while !at as node` /
   `at = !node.next` is rejected (`cannot reassign at while it is lent`); `while <at as node`
   is rejected (`node does not live long enough`); a field of type `!^Node[T]?` is rejected (a
   write view is never stored), so Rust's `IterMut` has no object form. Recursion works
   (`walk(!node.next, f)`), clean at 100,000 nodes, and **overflows the stack at 1,000,000**
   (`rig: stack overflow`). This touches second.rs `iter_mut`, the sixth chapter's cursors,
   and any "walk and edit in place" loop. It is an ownership question for the owner and CORE,
   not something a port should paper over.
2. **A suggestion that repeats the input.** `for x in <s.drain()`, and `for x in (<s.drain())`,
   are rejected with "method `drain` consumes `self`; write `<s.drain()`". Binding it first
   works. A diagnostic bug.
3. **A suggestion that is then rejected.** `?(@head)?.elem` is rejected with "lend each branch:
   `?(?@head)?.elem`", and that form is rejected with "a view cannot give up the resource
   inside it". So there is no one-line `peek`; the three-line `if … as` form stands.
4. **Tests compare awkwardly.** `List[Int]` has no `==` (`?a[..] == ?b[..]` works on slices);
   `(?Int)? == 42` is rejected though `Int? != 3` is accepted, so a test writes
   `(s.peek() ?? 0) == 42`. Rust's `assert_eq!(list.peek(), Some(&3))` reads better today.
5. **No fixed-place float printing found** in docs/STD.md (only `shortest`). nbody and
   spectralnorm print `{:.9}`; byte-identical output needs it (a std item, or a 10-line
   helper in the port, which the Speed expert should weigh). Unverified beyond the doc search.

## 3. House style: the checklist

**Names**
- Types `CamelCase`, everything else `snake_case`, constants at the margin `UPPER_SNAKE`
  (`SOLAR_MASS`, as examples/generics.rig's `HISTORY`).
- Keep the Rust's name where Rig's mantras agree (`push`, `pop`, `peek`); take std's word where
  they differ (`len` stored, `count` computed, `items()` for a read walk, `is_` for a test),
  and list each rename in the README's mapping table.
- Generic parameters `T`, `U`; `K`, `V` for maps; `n` for a value parameter.
- Vocabulary in comments and READMEs: lend, view, loan; object; self.

**Comments**
- The file's first `#` block says what the module is, in the present tense, and its last line
  names the Rust it ports: `# Ports too-many-lists/lists/src/second.rs.`
- A `#` sentence above a declaration only when it says what the name does not; none above
  `push`. Timeless prose; no history, no TODO, no commented-out code.
- No comparisons with Rust inside the code: those live in the README.
- Every `raw` block gets a `# raw:` line saying what it relies on.

**Layout**
- Two spaces, as every example. At most 100 columns. A long call breaks inside its parentheses,
  one argument per line, with a trailing comma; a chain breaks on `.` lines.
- One blank line between declarations, between methods, and after a field list. Never two.

**Order** (follow the Rust's order where it has one, so the side-by-side lines up)
- header comment; `use`s (std first); constants; types in the Rust's order, each with its
  methods inside it (Rust's separate `impl` blocks fold into the type); free functions;
  `sub main()`; `test` blocks; the `# expect:` block last.

**Loops**
- `for` by default: ranges, lists, slices, iterators (`for x in ?s.iter()`).
- `while cond : step` for an index loop with its own step; `while o as x` to walk an optional.
- A loop as a value (`for … break v … else d`) instead of a found-flag.
- Recursion for a write walk down owned links (finding 1), noted in the README with its depth.

**Method or function**
- A method when the value is the subject (`!s.push(x)`, `s.peek()`).
- A free function for an algorithm over values of equal standing (`advance(!bodies, dt)`,
  `energy(bodies)`) and for helpers on an optional slot (`place(!slot, key)`, as
  examples/tree.rig).
- No `new` where field defaults suffice (`Stack[Int]()` with `head: ^Node[T]? = none`);
  a `fun new` only when it computes something.
- `pub` exactly where the Rust has `pub`.

**Errors**
- Absence `T?`; expected failure `T!E` with a named `error` set; a bug panics.
- Pass on with `e!` / `e?`; handle with `catch` only where the Rust handles; `?? panic("why")`
  for Rust's `unwrap`/`expect`, with the reason.
- `task.isolate` only at a boundary (a connection handler), as Rust's `catch_unwind`.

**Tests**
- `test` blocks at the end of the port file, one per Rust `#[test]`, with the Rust's test name,
  so `rig test` output maps one to one. Not `.rig.test` files: those are the compiler suite's
  format, and `compare/` is outside the suite.
- A test with several checks writes guard lines, `return false if …`, and ends on a `Bool`,
  until `assert` with values lands. Concurrency tests run `rig test --seeds=20`.
- Each port passes `rig test` and its program runs clean under `RIG_SANITIZE=1`.

**`# expect:`**
- A runnable file ends with `# expect:` and the output for its default input, as `examples/`.
- A Benchmarks Game program's expect block holds the output for the input of the Rust's
  `N_out` file (nbody 1000, two lines); a large output (fasta, revcomp) is checked with `cmp`
  against `N_out` by the measuring script instead, and its expect block shows the first lines.
- A library with no `main` (the lists) has tests instead, and its bench driver has the expect.

## 4. The measures

**Code lines.** A line with code on it: no blank lines, no comment-only lines. `sloc.py`
(beside this report; `tokei`, `scc` and `cloc` are not installed) counts both languages one
way:
- Rust: block and line comments removed (`///` and `//!` too); items under `#[cfg(test)]` and
  `#[test]` functions left out. Rig: comment lines and the `# expect:` block left out; `test`
  blocks at the margin left out.
- `--tests` counts the tests on both sides. The headline is **without tests**; the README shows
  both. Imports, `pub`, attributes and a lone `}` count as code, as tokei counts them.
- Rust is counted **as published**, never reformatted; the README says when it is not
  rustfmt-clean (some Benchmarks Game programs pack fields on one line).

**Tokens**, beside lines, so layout cannot win: a string is one token, a name or number one,
each punctuation character one (so `::` is two, a sigil one). Lines can be gamed by joining;
tokens cannot.

**Same feature set.** Each count names the Rust files it covers. When a port leaves out a Rust
feature (mini-redis's tracing and clap CLI), the matching Rust is left out of the count and the
README says which. When the Rig adds something (a bench driver), it is counted apart.

Today's numbers from the tool: second.rs 86 lines / 618 tokens (148 / 1251 with tests);
fourth.rs 122 / 965; nbody.rust 133 / 1158 against the probe's 72 / 847 (the planet table
dominates both).

**Speed and memory** (the Speed expert owns the harness): release builds (`cargo build
--release`; `rig build --release`, Zig's safe mode, as the headline, and `--release=fast` as a
second row); interleaved, fastest of 10, 20 rounds when within 2%; the Mac for arm64 and pup
for x86, never burst; peak memory from `/usr/bin/time -l` (Mac) and `-v` (pup). Said as "N%
faster" or "N% slower".

**Same output.** `cmp` of each program's output against the Rust's (the Benchmarks Game's
`N_out`; for the lists and mini-redis, the Rust driver's output).

## 5. The per-project README (`compare/rig/{name}/README.md`)

Sections, in order:

1. **Title and one paragraph**: what the Rust is (source, license, commit), what the port
   covers, and the Rust files counted.
2. **Numbers**: one table (below).
3. **The hardest part, side by side**: one excerpt pair, at most 30 lines a side, then a
   paragraph on what dissolved and what did not.
4. **Mapping**: a short table, Rust construct to Rig form, for this project only (the full map
   is the Idiom expert's).
5. **Sigil ledger rows**: this project's rows (below); the totals live in `../ledger.md`.
6. **Gaps found**: each with its probe and where it went (a PR, a backlog row, an owner
   question). Empty is fine.
7. **Reproduce**: the commands, from `compare/`.

**Side by side in Markdown.** GitHub renders a fenced block inside an HTML table cell when the
fence has a blank line on each side:

````markdown
<table>
<tr><th>Rust (second.rs 33–37, 49–51, 72–84)</th><th>Rig (second.rig 18–40)</th></tr>
<tr><td>

```rust
...
```

</td><td>

```rig
...
```

</td></tr>
</table>
````

A plain viewer shows the two blocks one after the other, which still reads. The code in both
cells is never typed by hand: each `<td>` holds a marker,
`<!-- excerpt rust/too-many-lists/lists/src/second.rs 33-37,49-51,72-84 -->`, and a small
`excerpts.py` fills it from the files and fails when a range no longer matches, so excerpts
cannot drift from the code (`compare/` is outside the doc tests). Credit and license under the
table: MIT for too-many-lists and mini-redis, BSD-3 for the Benchmarks Game. **The ray tracer
has no license: its README shows Rig only, compared with the structure of Shirley's book,
never an excerpt of that Rust.**

**The numbers table:**

| | Rust | Rig | |
|---|---:|---:|---|
| Code lines (tests left out) | 86 | 40 | 53% fewer |
| Tokens | 618 | 325 | 47% fewer |
| Code lines with tests | 148 | … | |
| Time, Mac arm64 (fastest of 10) | … ms | … ms | N% faster |
| Time, pup x86 | … | … | |
| Peak memory, Mac / pup | … | … | |
| Output identical | | | yes (`cmp`) |

**The ledger rows**, one per sigil or form the port uses:

| Sigil | Uses | Where it reads naturally | Rust it replaces |
|---|---:|---|---|
| `<@field` (take) | 3 | `@head = ^Node(elem: <elem, next: <@head)` | `self.head.take()` |
| `(…)?` | 1 | `node = (<@head)?.unbox()` | `.map(\|node\| …)` |
| `?x` / `(?T)?` | 4 | `return ?node.elem` | `Option<&T>`, `as_ref()` |
| `from @` | 1 | `fun iter(?@) -> Iter[T] from @` | `Iter<'a, T>` and its lifetimes |

Counts come from a script, never by hand: `ledger.py` runs `rig normalize` on each port and
counts IR nodes (`move`, `read`, `write`, `clone`, `box`, `share`, `propagate_none`,
`read_view`, `write_view`, `call task`, the `>` member, …), since every sigil survives as a
named node (North Star 3). A prototype of the count is one `grep -o '([a-z_?!.]*' | uniq -c`.

### Filled-in example: the section for second.rs

> ### The hardest part: looking without taking
>
> *(Rust column: `<!-- excerpt rust/too-many-lists/lists/src/second.rs 33-37,49-51,72-84 -->`.
> Rig column: `<!-- excerpt rig/too-many-lists/second.rig 18-40 -->`, which is the `peek`,
> `iter` and `Iter` shown in section 2 above.)*
>
> The Rust needs three tools to hand out a reference into its own list: `as_ref` to look
> into the `Option` without moving it, `as_deref` to see through the `Box`, and a named
> lifetime on `Iter` and its `impl` to tie the reference to the list. The book spends a
> chapter on that lifetime.
>
> The Rig says the same with what it already has. `if @head as node` views the node in place
> and `?node.elem` lends the element out; the result type `(?T)?` says "maybe a view". The
> iterator holds a view, `at: ?^Node[T]?`, and `from @` says it views the stack, so
> `for x in ?s.iter()` keeps `s` lent while the loop runs, and the checker rejects a `push`
> inside it. No lifetime is written anywhere. Dropping the list needs no code: the runtime
> releases a chain of a million boxes without recursing, where the Rust writes its own `Drop`.
>
> What did not dissolve: `iter_mut`. A write view is never stored, so there is no `IterMut`
> object, and a local write view cannot be re-pointed down the list while it is lent; the
> port walks recursively (`walk(!node.next, f)`), clean at 100,000 nodes and out of stack at
> 1,000,000. Raised with the owner.

## 6. Layout of `compare/rig/`

```
compare/rig/
  README.md            the index: one row per project (and per Benchmarks Game program),
                       the headline numbers, the counting rules in one paragraph, links
  ledger.md            the sigil ledger across all four (below)
  tools/               sloc.py, ledger.py, excerpts.py, and the Speed expert's timing script
  too-many-lists/
    README.md
    first.rig second.rig third.rig fourth.rig fifth.rig   one file per Rust file, same stem
    bench/             the driver pair, bench.rig and a small cargo crate depending on
                       ../../../rust/too-many-lists/lists by path (the clone stays untouched)
  benchmarksgame/
    README.md          one table for all ten, then a short section only where a program
                       has a hardest part worth showing
    nbody/nbody.rig        ports the plainest Rust (header names it: nbody.rust)
    nbody/nbody-fast.rig   ports the fastest Rust version (header names which)
    ... the same for the other nine; expected output read from ../rust/…/N_out
  ray-tracing/
    README.md          Rig only, against the book's chapters; no Rust excerpts
    main.rig vec3.rig ray.rig hit.rig material.rig camera.rig   a directory module
  mini-redis/
    README.md
    one .rig per Rust module it ports, same stem (db.rig, server.rig, frame.rig, …)
```

**`ledger.md`**: rows in QUICK.md's order (binding, taking and copying, lending, holding,
failure and absence, concurrency), then the forms (`keeps`, `from`, compile-time brackets,
`$name(…)`, `:symbol`, `raw`, `inline`/`called`/`rarely`, closure capture modes, `*|…|`,
`defer`/`errdefer`, labels, loops as values, several results, `swap`, `Table`/`Slot`, `Simd`,
`*Frozen`, `*Cell`, `*Actor`, the frozen four: `*{A}`, `~{A}`, `once ?fun`, user `api`/`add`).
Columns: one count per project, a total, one link to the most natural use, and a verdict
(natural, forced, unused). It ends with two lists for the owner: **unused** (no natural use in
any port) and **forced** (used, but read badly).

## 7. Decisions (defaults first)

1. Headline line count **excludes tests** on both sides; a second column includes them. Default yes.
2. Report **tokens** beside lines. Default yes.
3. Rust counted **as published**, not rustfmt'd. Default yes.
4. Tests as `test` blocks in the port file, **one per Rust test, Rust's names**. Default yes.
5. Side-by-side as an **HTML two-cell table filled by `excerpts.py`** from line ranges. Default yes.
6. The ray tracer's README shows **Rig only**. Default yes (no license).
7. Benchmarks Game: **plain and fastest Rust each ported**, `name.rig` and `name-fast.rig`,
   **one README for all ten**. Default yes.
8. Headline Rig speed is **`--release` (safe)**, with `--release=fast` as a second row. Default yes.
9. Finding 1 (no iterative write cursor) goes to the **owner as a CORE question**; ports
   recurse meanwhile and say so. Findings 2–3 go in **one diagnostics PR**; 4–5 to the backlog.
