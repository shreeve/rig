# Review: PR #95 `polish` (head aea73c3f, base 48f20f2a), round 1

I built aea73c3f in a detached worktree and checked it with single programs,
the targeted suite subset (`doc/QUICK not_scope not_comparison cache_trim
doc/FAQ doc/WELCOME doc/DESIGN doc/CORE vocab style`: 80 passed, 0 failed,
3 pending), and cache tests run only under a fake `XDG_CACHE_HOME` in
scratch directories. Probes are in `review-polish-1-probes/`.

**Grades.** P1: fix before landing. P2: should fix (a false hint, or a rare
but real failure). P3: polish.

**Verdict.** The `not` rule, the reworded messages, QUICK, and the honesty
edits are sound, apart from one new false hint (F3). Cache trimming never
reached outside the cache home in any test, and symlinks are handled
safely. `rig clean`, though, deletes `<base>/rig` whole, without checking
what is in it. With a relative or unusual `XDG_CACHE_HOME`, that can delete
a user's source tree (F1). Fix F1 before landing. F2 and F3 are small and
should be fixed in this round as well.

---

## F1 (P1). `rig clean` deletes whatever directory `<base>/rig` names, including a relative path

`cacheHome` takes `XDG_CACHE_HOME` or `HOME` as given. An empty value is
already treated as unset (`Env.get`). A **relative** value is used against
the cwd, and `clean` then calls `deleteTree` on `<base>/rig` without
checking what it holds. The XDG Base Directory spec says a relative
`$XDG_CACHE_HOME` must be ignored. Before this PR, such a value only made
rig *write* into `./rig`. Now `rig clean` deletes it.

```sh
mkdir -p proj/rig/src && echo "my source" > proj/rig/src/main.zig && cd proj
XDG_CACHE_HOME=. rig clean        # rig: removed ./rig   (source tree gone)

mkdir -p home2/rig && echo important > home2/rig/thesis.txt
XDG_CACHE_HOME=$PWD/home2 rig clean   # rig: removed .../home2/rig
```

Both reproduced. The second case covers anyone with `XDG_CACHE_HOME=$HOME`
and a checkout at `~/rig`, which is the obvious place for this project.
`XDG_CACHE_HOME=/` makes `rig clean` delete `/rig`.

The trim is much safer: it deletes only top-level directories named
`<name>-<16 hex>` that are older than 5 days, plus `.trash-*`. But the same
relative base can still reach directories that are not rig's (for example
`./rig/foo-0123456789abcdef`).

**Fix:**
- In `cacheHome`, for the trim and `clean` (and preferably `outputDir`),
  ignore any `XDG_CACHE_HOME` or `HOME` that is not absolute, as XDG
  requires.
- Make `rig clean` remove only what rig makes: entries that pass
  `isPackageDir`, `.trash-*`, and `.trimmed`. Then remove the home with
  `rmdir` only if it is empty. Another option is a marker file, such as
  `CACHEDIR.TAG`, that rig writes on first use and `clean` requires.
- Add a test: `XDG_CACHE_HOME=. rig clean` beside a `rig/` holding a
  non-package file leaves that file.

## F2 (P2). Trimming removes the package of a run in progress; a long run then reports "did not run"

`rig run` marks its package used only once, before `zig run`. The program
creates `.started-<hex>` inside that package directory, and `rig` stats
the file after the program exits. If any other `rig run`, `build` or
`test` trims while the program is still running past the 5-day mark (a
server, a long job), the directory is renamed and deleted. A successful
program then gets exit status 125.

```sh
# under a fake XDG_CACHE_HOME (scratch only)
rig run long.rig &                 # sleeps 20 s, then prints "done"
sleep 10; touch -t 202001010000 $XDG_CACHE_HOME/rig/long-* $XDG_CACHE_HOME/rig/.trimmed
rig run hello.rig                  # trims long-*
wait
# done
# error: rig: the program did not run: `zig run` exited with status 0, and the program left no sign that it started
# rc=125
```

There is a narrower race of the same kind. `trimCache` stats every entry
first, then renames and deletes them one by one, and deleting old
`.zig-cache` trees can take seconds. A concurrent build that reuses a
stale package (touched after the stat) can have it renamed away
mid-build. Touching the directory before `writePackage` does not close
that gap.

**Fix:**
- Skip any package that holds a `.started-*` entry, which marks a run in
  progress.
- Re-stat each entry just before its `rename`.
- Optionally, move the touch to before `writePackage`.

## F3 (P2). New copy-rejection hint offers `<p.o` where it cannot compile

`reportAlias` offers "`<x` to take it out (leaving `none`)" for every
optional part. It does so even when the part is reached through a read
view or a `*T` handle, where the move is rejected:

```rig
struct Bag
  items: Vec[Int]
struct H
  o: Bag?
sub viaread(p: ?H)
  x = p.o        # hint: write `<p.o` to take it out (leaving `none`), `+p.o` to clone it, or `?p.o` to view it
sub viashared(rc: *H)
  x = rc.o       # hint: write `<rc.o` to take it out ...
```

Applying the hint (`x = <p.o`, `x = <rc.o`) gives:
- `cannot take through a read view (`?T`); take a write view (`!T`) to mutate`
- `cannot take through a shared handle (`*T`) ...`

The old message made no such offer. Offer `<` for a part only when the
path to it allows a write: no `?T`, `*T` or `String` link, the same check
`requireAccess(.lend_write)` makes. Add a reject test covering both cases.
(probes `m2.rig`, `f2.rig`)

## F4 (P3). Captured-value messages still call an owner a "handle" and suggest `~v`

The messages were reworded but kept the same wrong advice for a captured
owner that is not a handle:

```rig
fun eat(v: Vec[Int]) -> Int
  v.len
sub main()
  v: Vec[Int] = Vec()
  f = *|<v| eat(<v)   # cannot move captured `v`; ... Use `+v` for another handle, `~v` for a weak one, or call its methods
```

The other message (`f = *|<v| eat(v)`) says "`v` is a handle the closure
captures ... write `+v` for another handle, or `~v` for a weak one".

For a `Vec`, `~v` is rejected (`~` weak reference requires a shared handle
`*T``), and `+v` is a clone, not "another handle". The substance predates
this PR (the old message said `~v` too), but "is a handle" is new wording.
Choose the fixes with `sema.cloneable`, as `reportAlias` now does, and
offer `~` only for `*T`. (probe `cap.rig`)

## F5 (P3). Smaller message and doc nits

- **Generic callee.** For `fun keep[T](x: T)`, `keep(v)` says "make its
  parameter a `?Vec[Int]`". The parameter is `T`, so the fix is `?T`
  (probe `gen.rig`).
- **Inside a loop.** For `w = v` inside a loop over an outer `v`, the copy
  message lists `<v` first, which is then rejected ("use of `v` after
  move"). The `+v` and `?v` alternatives are right. This predates the PR
  (probe `f3.rig`).
- **Multi-line comparison.** A comparison under `not` that spans lines
  puts a raw newline into the hint (`write `a\n    <= 2`, or ...`). Pass
  both texts through `oneLine` (probe `e.rig`). `rewrite.py`'s
  single-line `MESSAGE` regex also skips such a site. That changes no
  meaning: the compiler still rejects it.
- **Future-dated stamp.** A `.trimmed` dated in the future (after a clock
  set ahead and then corrected) turns trimming off until that date, and a
  future-dated package is never removed. Both are safe, but treat a
  negative age as stale.
- **Blocking first trim.** The first trim after upgrading runs
  synchronously before `zig` and may delete tens of GB (48 GB was seen),
  with no message. Consider printing "rig: trimming the cache" when it
  removes anything.
- **Wording.**
  - `rig clean` on a missing directory says "is already empty", where
    "does not exist" or "nothing to remove" would be accurate.
  - QUICK's "A bare argument is lent to read" holds only where the
    parameter is a view. CORE says "an argument where a view is
    expected"; a bare owner passed to an owning parameter is rejected.
  - DESIGN now lists drops at scope end as implicit, then says "There is
    no hidden refcount traffic". A `*T` leaving scope releases its count
    unmarked, so "no refcount traffic but the release at scope end" would
    match the paragraph.

---

## Checked and found correct

- **`not` rule, the cases it catches.** It rejects comparisons under
  `not` in conditions, `while` headers, postfix `if`, match guards,
  ternaries, `return`, module constants, closure bodies, array elements,
  a parenthesized whole (`(not a > 2)`), generic bodies (instantiated or
  not, reported once), nested `not not a == 1`, `not a > (b)`,
  `not (a) > b`, and a comparison split across lines with a comment.
- **`not` rule, valid code.** It rejects no valid unambiguous form:
  `not (a > b)`, `not(a > 2)`, `not done`, `not bag.is_empty()`, and
  `not a and b` are accepted.
- **Hints are exact.**
  - Integers (`Int`, `U8`, char literals): exact.
  - `String`: exact.
  - Enums (`c != .green`), optionals (`o != none`), structs, `Bool`, and
    `Float` `==`: they get `!=`, which is exact even for NaN.
  - `Float` and generic `T` orderings: parentheses only.
  - `Text` and `T?` cannot be ordered at all.
- **Flip text.** The operator search inside the gap between the two
  sides handles parenthesized sides (`(1) <= 2`, `1 <= (2)`) and an
  expression side (`1 + 2 <= 3`).
- **`rewrite.py`** only inserts `(` after `not ` and `)` after the exact
  operand text the diagnostic printed. The parse, and so the meaning, is
  unchanged.
- **Copy-message fixes applied and run sanitizer-clean** (`f1.rig`):
  `<v`, `+v`, `?v`, `<h.o`, `+h.o`, and a `?Vec[Int]` / `?Bag?`
  parameter.
- **Closures in copy messages.** A closure callee is not named
  ("make its parameter ...") in the copy message.
- **Receiver hints** print the real call:
  - `!v.push(1)`, `(!v).pop()`, `!c.bump(2 + 3)`, `!mk().bump(1)`
  - `<c.take()` and `?(c.take())`
  - `(!f).take()` → `<f.take()`
  - `(c).bump(1)` → `!c.bump(1)`
  - `?C.get()` → `?(C.get())`
- **Symlinks in the cache.** A symlink named like a package (old) and a
  `.trash-*` symlink are both skipped (`entry.kind != .directory`). An old
  package holding a symlink to an outside directory is removed without
  touching the target: Zig 0.17's `deleteTree` opens with
  `follow_symlinks = false` and unlinks links. A symlinked cache home is
  unlinked by `rig clean`, not followed.
- **Missing `HOME`/`XDG_CACHE_HOME`.** An empty `XDG_CACHE_HOME` falls
  back to `HOME`. With neither set, `rig clean` fails with a message and
  the trim is skipped.
- **`RIG_OUT_DIR` / `RIG_BUILD_STORE`.** A run with either set neither
  touches nor trims.
- **QUICK.md.**
  - Its program runs under the suite (`doc/QUICK`, passes), and its
    output is right.
  - The sigil table, receivers, `*<x`, `e?`/`e!`, `return E.name`, and
    `@name(T)` agree with SPEC and CORE. (The minor overstatement is in
    F5.)
- **SPEC §5's new `rig reject` example** and the CORE, WELCOME and DESIGN
  doc examples pass.
