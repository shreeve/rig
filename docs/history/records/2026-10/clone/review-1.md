# Review: `+x` of foreign types and Map/Set (worktree `clone`, 84e04b7c0)

Probes: `/private/tmp/claude-501/-Users-shreeve-Data-Code-rig/d74fe786-4ae4-440a-9e7f-c765153ac298/scratchpad/clone-review/pNN/`
(run with `run.sh DIR`). All under `RIG_SANITIZE=1`.

## 1. BLOCKER: a generic type reached again with other arguments is taken as cloneable

`fieldsCloneable` treats any declaration already in `seen` as cloneable
(`for (seen) |t| if (t.ctx == ctx and t.sym == sym) return true;`), keyed
by the declaration only, not its arguments. The second visit of the same
generic with different arguments never checks those arguments, so a
drop-bodied type nested one generic deeper is cloned.

New with this change (Map was not cloneable on main) — p45, only std types:

```rig
use std.file

sub main()!
  m: Map[Int, Map[Int, file.File]] = Map()
  inner: Map[Int, file.File] = Map()
  !inner.put(1, file.create(".../c.txt")!)
  !m.put(1, <inner)
  m2 = +m
  _ = <m
  g = file.create(".../d.txt")!
  _ = <m2           # closes the reused fd, which is g's
  !g.write("hello")!
```

Accepted; runs to `error: FileError.denied` (the clone's File closed g's
fd). p40 (`Map[Int, Map[Int, Res]]`, Res with a drop body) prints
`drop 5` twice. p38: `b.Outer[Res]` holding `lib.Wrap[lib.Wrap[T]]`
across three modules, also two drops. Also reaches `Entry[K, V]` inside
every Map-of-Map.

Pre-existing for local generics (same output on main's `bin/rig`):
p39 `Wrap[Wrap[Res]]`, p22 `Pair[A, B]` with `next: ^Pair[B, A]?`
(clones `Pair[String, Res]`, double drop), p25 with `file.File` (double
close). `List[List[Res]]` is rejected because List is special-cased.

Fix (fix the class): on a revisit, do not return true outright; when a
frame is present, require each of its type arguments to clone:

```zig
for (seen) |t| if (t.ctx == ctx and t.sym == sym) {
    const f = frame orelse return true;
    for (f.args) |arg| if (!deepCloneable(f.args_ctx, arg, f.parent, seen)) return false;
    return true;
};
```

This terminates (a revisit never re-enters fields) and is sound: the
non-argument structure was checked on the first visit; only the
arguments differ. Cases: p38, p39, p40, p45, p22 as `fail`; keep p19
(`Tree[T]` with `List[Tree[T]]`, `Node[T]` with `^Node[T]?`) passing.

## 2. Low: loan note names the dropped original

p34 (`json.Doc` cloned after `parse(?s)`, `_ = <d`, then `<s`): correctly
rejected, but the note says the loan "lasts while `d` is used" when it is
`d2` (the clone) that keeps it. Pre-existing note wording; cosmetic.

## Checked and correct

- Foreign generic with local drop type (`lib.Wrap[Res]`, p01), drop type
  only behind a private generic field (p02), nested generic in one
  module (p03), foreign enum generic (p18), recursive foreign generic
  with drop arg (p20), third-module drop type behind a private field
  (p17), std `file.File`, `lib.Wrap[file.File]`, `Map[Int, file.File]`
  (p48): all rejected with the right message.
- Unique via Map/foreign (p11, p24): "holds a unique value".
- Cell in foreign private field: by value it is rejected at the
  declaration; behind `*Q` it bumps (p30).
- `Map[Int, *P]`, `Map[Int, ~P]`, private `*P`/`~P` in a foreign type
  (p06, p07, p28): bump, sanitizer clean.
- `Map[?String, Int]`, `lib.Wrap[?String]`, Map of foreign wrap of
  views, `+r`/`+?m` through views, json.Doc (p08, p09, p31-p34, p42-p44):
  the clone carries the loan; moving the source is rejected.
- Map of Map of Set of String (p13), foreign enums with payloads (p15),
  three-module chains (p16, p37), `|+m|` capture (p26), clones handed to
  tasks (p27), `text.Interner` (p36): correct output, no leaks.
- `Map[Int, !Int]` is rejected at the type; a Signal cannot be made by
  value, so `Map[Int, Signal[Int]]` (accepted) can only be empty.
- Generic body `+w` with `w: ?lib.Wrap[T]`, instantiated with Res (p29):
  rejected at the instantiation.
- Oracle: `test/oracle/lower.zig` (`.clone`) models a clone as a new
  owner carrying the operand's loans and does not judge cloneability, so
  it neither catches finding 1 nor disagrees with the change.

## Resolution

Finding 1 is fixed: `fieldsCloneable` checks, on reaching a declared
type again, that each type argument it is reached with clones, so
`Map[Int, Map[Int, Res]]`, `Wrap[Wrap[Res]]`, and the three-module
`Outer[Res]` have no clone, and `Node[T]`'s recursion still clones. The
probes p38, p40, and p45 are rejected; cases in
`test/rig/ownership-clone.rig.test`. Finding 2 (a note's wording on a
cloned `json.Doc`) predates this change and is left.
