# Rig Core (draft for review)

This is the yardstick for the consolidation. It states the whole ownership
model in plain sentences. Anything in the compiler, SPEC, or the standard
library that does not follow from these sentences is a candidate to
harmonize, simplify, or cut. A new feature enters only if it can be stated
as a consequence of this page, in one paragraph, with no exception list.

Every rule is marked with its status:

- **built**: on `main` today
- **branch**: built on a branch that has not landed yet
- **decided**: you chose it; not built yet
- **open**: needs your decision (listed at the end)

---

## 1. Four kinds of value

Every value is one of four kinds, decided by its type:

| Kind | Examples | Plain use | Status |
|---|---|---|---|
| **plain** | `Int`, `Bool`, a struct of plain fields | copies | built |
| **owning** | `Vec[T]`, `Text`, `Box[T]`, a struct holding an owner | moves; one owner; dropped once | built |
| **handle** | `*T` (counted), `~T` (weak) | moves; `+h` adds a count | built |
| **view** | `?T`, `!T`, `[]T`, `![]T`, `String` | a read view copies, a write view moves | built (String as a checked view: branch) |

A type's kind follows from its parts. One exception needs a word: a type
that holds only plain data but must not be copied, like a random generator
whose copy would repeat its numbers. It declares that on the type (see
open decision 1). It does not fake a `drop` body. **open**

A struct that holds a `Cell` is not plain: copying it would fork state that
should be shared. **open** (decision 2)

## 2. The core, in ten sentences

1. **A bare name only reads.** It copies plain data and views, and reads
   owners and handles in place. It never moves, clones, writes, or drops
   anything. **decided** (today some positions still require `?`)
2. **`<x` moves, `+x` makes a new owner, `-x` drops now.** `+x` is a copy,
   a count bump, or a deep copy, as the type says. **built** (`+` on a
   `Vec` or `Box` is not built yet)
3. **An owner that is not moved is dropped where its scope ends.** A value
   no name holds is dropped where its statement ends (§3). **built / decided**
4. **`?x` lends `x` to read, `!x` lends it to write, as whichever view the
   context expects** (§4). A read lend may go unwritten (sentence 1); a
   write lend is always written. **partly built; the full table is decided**
5. **A value has any number of read loans, or one write loan, never both.**
   This holds for every type, numbers included. **built**
6. **A loan lasts until the last use of every view that carries it,
   wherever that view went:** a field, a list, an optional, a closure, a
   result. **built** (String views: branch)
7. **A function returns a view only of what it was lent,** and its result
   carries the loans of everything it was lent. **built**
8. **`*x` moves `x` into a counted box whose handles only read.** `~h` holds
   it weakly, and `h.upgrade()` is the way back. **built**
9. **Every change is marked by `!` where it is lent, with one exception:**
   a `Cell` changes through any path, and so accepts only values that carry
   no loan. All shared storage (`Cell`, `Signal`, `*T`, owned closures)
   follows that rule. **built** (checked per value: decided)
10. **`e!` propagates a failure and `e?` an absence.** Failing is always
    written: `return E.name`, never a bare value. Every fallible call says
    what happens to its failure: `!`, `catch`, or `??`. **mostly built**
    (a bare error value on a function's last line still fails silently:
    **open**, decision 3)

Only code inside `raw` may break these rules. **built**

## 3. Temporaries (one paragraph)

An expression either **takes** its value or only **reads** it.
- **Taking:** a binding, an argument to a parameter that owns it, `return`,
  a stored field or element, or `<`.
- **Reading:** a `print` or `Text(...)` argument, an `==` operand, `?e`, a
  receiver, or a field or element read.

Reading never moves a name, whatever form reads it. So `print(a if c else b)`
and `print(o ?? d)` move nothing. A value made where it is only read (a
call's result, a constructor, `+x`) has no name, so its statement is its
scope. It is a **temporary**, dropped when the statement ends: the last one
made first, and also when the statement fails or leaves early.

A borrow of a temporary, or a view made from one, may be used only within
its statement. An `if` or `while` condition, a guard, and the subject of a
`match` or `for` are statements of their own. A call's result that
`if … as`, `while … as`, `match` or `for` binds is taken, as `<e` would take
it. **decided** (the branch has a wider rule that is being cut back to this)

## 4. One lend table

`?x` and `!x` lend the view the context expects. This one table replaces
six separate conversions:

| Owner `x` | `?x` can lend | `!x` can lend |
|---|---|---|
| any `T` | `?T` | `!T` |
| `[N]T`, `Vec[T]` | `[]T` | `![]T` |
| `Text` | `String` | `!Text` |
| `Box[T]` | the views of `T` | the write views of `T` |
| `*T` | the read views of `T` | nothing; a handle only reads |
| `X?` | `View?` for each view of `X` | |

The table composes, so `Box[Text]` → `String` needs no rule of its own.
A slice `x[a..b]` is the same lend, of part of `x`. So `sort.sort(!v)`
works for a `Vec` as it does for an array, and one `fun area(s: ?Shape)`
serves a `Shape`, a `Box[Shape]`, and a `*Shape`.
**partly built** (arrays, Text, Box); **decided** (Vec, `*T`, optionals)

## 5. Containers hold anything

`Vec`, arrays, and `![]T` hold any type: plain values, owners, handles,
views. Each element is a place:
- `v[i]` reads it (sentence 1);
- `?v[i]` and `!v[i]` lend it;
- `<v[i]` takes an optional element;
- `swap`, and therefore sorting, work for any element type.

So `Vec[Text]` and a list of records that each own a string just work.
**decided** (today `Vec[Text]` is rejected and `Vec[Box[Text]]` is the
workaround)

## 6. Assignment

`x = e` evaluates `e` first, then finds `x`'s place, then stores. Indexes
are evaluated outside in. This matches Rust. **branch** (safety-net, PR #31)

Assigning to a borrow place:
- assigning a **borrow** re-points it;
- assigning a **value** writes through it.

This is the same for locals and fields. `new` only shadows, and accepts
every binding form. **open**, decision 4 (today a local `w = !m` is rejected
while a field `h.w = !m` re-points)

## 7. Outside the core: syntax, not ownership

These are single documented syntax rules, not ownership rules:
- `-x` as a statement drops; `-x` as a value negates.
- The receiver-sigil rule: `!v.push(x)` applies `!` to `v`, not to the
  result.
- `=!`, a binding that never changes. **open** (decision 5)
- `!` before a call whose `Bool` result is used, as in `dup = !s.insert(1)`,
  reads as "not" to C, Rust, and JavaScript readers. **open** (decision 6)
- Labels, `catch` forms, `pass`, `??`.

## 8. Inside the compiler (not user-visible)

Each type gets separate facts instead of one "owning" flag:
- copyable;
- needs cleanup;
- shares memory when copied;
- may hold a borrow;
- may be cloned;
- lives for the whole program (literals, `os.args`).

Each expression gets one classification: what it hands over (a place, a
fresh value, a borrow, or a view). Every pass reads these facts; none
decides them again by looking at syntax. **decided** (from the
consolidation and the outside review)

## 9. How a feature earns its way in

- It fits one SPEC paragraph, with no exception list.
- Its rules follow the value's type, never where the value came from.
- It is written as a desugaring into forms this page already covers.
- A second round of soundness fixes stops it for redesign.
- It passes the regression corpus and runs clean under the sanitizer.
- It answers a line that failed in a real program; it is not added for
  parity with Rust or Zig.

---

## Open decisions

1. **The word for a move-only type that owns nothing.** For example
   `struct Rng unique`. Other candidates are `owns` or `move`. Lean:
   `unique`, because it says why (no second copy) without implying cleanup.
2. **A struct holding a `Cell` is not plain.** `b = a` then needs `<a` or
   `+a`, which ends silent state forks. Lean: yes.
3. **Failing is always written.** A bare error value or error binding on a
   function's last line would be rejected, with the hint `return E.bad`.
   Lean: yes.
4. **One `=` on borrow places.** Assigning a borrow re-points it and
   assigning a value writes through, for locals and fields alike. Lean: yes.
5. **`=!`.** Options:
   - keep it;
   - replace it with a word, e.g. `fix x = e`;
   - drop fixed bindings, since the emitter already picks `const` or `var`.

   Lean: replace it with a word. It removes `!`'s fourth meaning and the
   spacing trap (`x =! y` versus `x = !y`).
6. **A write call whose `Bool` result is used needs the long form**
   (`dup = (!s).insert(1)`) everywhere, not only in conditions. Lean: yes.
