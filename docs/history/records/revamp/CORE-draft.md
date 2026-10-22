# Rig Core (draft 3)

This page states Rig's whole ownership model in plain sentences. It is the
yardstick for the language: anything in the compiler, the SPEC, or the
standard library that does not follow from these sentences gets harmonized,
simplified, or cut.

A new feature enters only if it fits this page in one paragraph, with no
exception list. Draft 2 folds in six audits of the code; their reports are
in `.git/revamp/reports/core-audit/`.

**Status markers:**

- **built:** on `main` today.
- **branch:** on the strings branch, not landed yet.
- **decided:** agreed; not built.
- **open:** waiting on a decision (listed at the end).

**Three words:**

- To **lend** `x` is to let someone use it without taking it.
- A **view** is the borrowed thing they get: `?T`, `!T`, `[]T`, `![]T`, or
  `String`.
- A **loan** is the compiler's record that a view of `x` exists. While a
  loan is live, `x` may not change, move, or drop in a way the view would
  notice.

**Scope:** this page covers ownership only. Type rules (generics, modules,
numeric conversions) and pure syntax are in SPEC and SYNTAX.

---

## 1. Four kinds of value

| Kind | Examples | A plain use | Status |
|---|---|---|---|
| **plain** | `Int`, `Bool`, enums, structs whose fields are all plain | copies | built (with false rejections, fixed by one `copyable` fact) |
| **owning** | `Vec[T]`, `Text`, `Box[T]`, structs holding an owner | moves; one owner; dropped once | built (`Text`: branch) |
| **handle** | `*T` (counted), `~T` (weak) | moves; `+h` adds a count | built |
| **view** | `?T`, `!T`, `[]T`, `![]T`, `String` | a read view copies; a write view moves | built (`String` as a view of a `Text`: branch) |

**Struct and enum kinds.** A struct's or enum's kind follows from its
parts: all plain parts make it plain, and any owner makes it owning.

**Two kinds the parts can't show:**

- **A type that must not be copied but owns nothing**, such as a random
  generator whose copy would repeat its numbers. It says so on the type:
  `struct Rng unique`. Today `Rng` fakes an empty `drop` body. **decided**
- **A type that holds a `Cell`**, or a bare `Cell[T]`, is not copyable,
  because a copy would fork state that should be shared. **decided**

## 2. The core, in ten sentences

1. **A bare name only reads.**
   - It copies plain data and read views, and reads owners and handles in
     place.
   - It never clones, writes, or drops, and it moves only where the value
     leaves for good: `return x`, or `x` as the last value of a function
     or block. **decided**
   - Status: **decided**. Today a `?` is still required in some positions:
     a `?T` argument, a `for` over a `Vec`, `if o as x`, a `match` on a
     `Box`.
2. **`<x` moves, `+x` makes a new owner, `-x` drops now.**
   - `+x` is a copy, a count bump, or a deep copy, as the type says.
   - Status: **built** for plain data, handles, closures and `Text`
     (branch). Not built for `Vec`, `Box`, `Text?`, `Box[Text]`, or structs
     holding an owner.
3. **Drop points.**
   - An owner that is not moved is dropped where its scope ends. **built**
   - A value no name holds is dropped where its statement ends (§3).
     **branch/decided**; `main` rejects such values instead.
4. **`?x` lends `x` to read, and `!x` lends it to write, as whichever view
   the context expects** (§4).
   - A read lend may go unwritten (sentence 1); a write lend is always
     written.
   - Status: **partly built**; the full table is **decided**.
5. **A value has any number of read loans, or one write loan, never both.**
   This holds for every type, numbers included. **built**
6. **A loan lasts until the last use of every view that carries it,**
   wherever that view went: a field, an array, an optional, a closure, a
   result. **built** (`defer` exits: hotfix B1)
7. **A function returns a view only of what it was lent, or of something
   that lives for the whole program** (literals, module constants,
   `os.args()`). Its result carries the loans of everything it was lent.
   **built** (a narrower, signature-based origin rule: decided)
8. **`*<x` moves `x` into a counted box, and `*S(...)` boxes a new value.**
   - Handles only read, except through a `Cell`.
   - `~h` holds the box weakly, and `h.upgrade()` is the way back.
   - Status: **built**
9. **Shared storage.** Every change is marked by `!` where it is lent, with
   one exception: a `Cell` changes through any path.
   - `Cell`, `Signal`, and owned closures accept only values that carry no
     loan.
   - A `*T` instead carries its contents' loans on every handle.
   - Status: **built**. Checked per type for `Cell` and `Signal`, plus per
     value; per value for closures.
10. **`e!` propagates a failure, and `e?` propagates an absence.**
    - Every fallible call says what happens to its failure: `!` or
      `catch`. **built**
    - Failing is always written: an error value meets a `T!` only as the
      operand of `return`. **decided**

Only code inside `raw` may break these rules. **built**, once hotfixes B1
and B2 land.

## 3. Temporaries

**Taking and reading.** An expression either *takes* its value or only
*reads* it.

- **Taking:** a binding, an argument to a parameter that owns it,
  `return`, a stored field or element, or `<`.
- **Reading:** a `print` or `Text(...)` argument, an `==` operand, `?e`, a
  `?self` receiver, or a field or element read.

Reading never moves a name, whatever form reads it: `print(a if c else b)`
moves nothing.

**What counts as a temporary.** A value made where it is only read has no
name: a call's result, a constructor, `+x`, or a block or `match` value. So
its statement is its scope. It is a *temporary*, dropped when the statement
ends:

- the last made first;
- also when the statement fails or leaves early.

**Borrows of a temporary.** A borrow of a temporary, or a view made from
one, may be used only within its statement.

**Headers are their own statements:**

- an `if` or `while` condition;
- a guard;
- the subject of a `match` or `for`.

So `if text.starts_with(?Text(a, b), "x")` works. But
`if text.cut(?Text(...), "=") as kv` must bind the Text first, because `kv`
outlives the header.

**Bound call results are taken.** A call's result that `if … as`,
`while … as`, `match`, or `for` binds is taken, as `<e` would take it.

**Status: decided.** The branch has a wider rule, which is being cut back to
this one.

## 4. One lend table

`?x` and `!x` lend the view the context expects. The table composes, and
replaces six separate conversions:

| Owner `x` | `?x` lends | `!x` lends | Status |
|---|---|---|---|
| any `T` | `?T` | `!T` | built |
| `[N]T`, `Vec[T]` | `[]T` | `![]T` | arrays built; Vec decided |
| an element place `v[i]` | the views of the element | the write views of the element | decided |
| `![]T` | `[]T` | | built |
| `Text` | `String` (also `String?`) | `!Text` | branch |
| `Box[T]` | the views of `T` | the write views of `T` | one level built; composing decided |
| `*T` | the read views of `T` | nothing (a handle only reads) | decided |
| `X?` | `View?` for each view of `X` | | decided |
| a function or closure | `?fun` | | built |

A read view of plain data copies. It carries no loan once copied out, as
with a call's `?Int` result.

A slice `x[a..b]` is the same lend, of part of `x`. So:

- `sort.sort(!v)` works on a `Vec` as it does on an array;
- one `fun area(s: ?Shape)` serves a `Shape`, a `Box[Shape]`, and a
  `*Shape`.

## 5. Containers and fields hold anything

`Vec`, arrays, `![]T`, and struct fields hold any kind of value.

An element or field is a place:

- `v[i]` reads it (sentence 1);
- `?v[i]` and `!v[i]` lend it;
- `<v[i]` takes an optional element;
- assigning to it drops the old value.

`swap`, and so sorting, work for any element. `copy`, `fill`, and
`[n of x]` duplicate values, so they need copyable elements.

So `Vec[Text]`, `Vec[Vec[Int]]`, and a list of records that each own a
string just work.

**Status:** fields are built. Containers are **decided**: today about six
early rejections block them, and the workaround is `Vec[Box[Text]]`.

## 6. Bindings and assignment

**Evaluation order.** `x = e` evaluates `e` first, then the indexes in `x`
from left to right, then finds `x`'s place, then stores. This matches Rust.
**built**

**Bindings.** A plain binding may be reassigned. Parameters and `const`
bindings may not (`const x = 5`; today written `x =! 5`).

**Borrow places.** Assigning a borrow to a borrow place re-points it, and
assigning a value writes through. This holds for locals and fields alike.
`new` only shadows, and accepts every binding form. **decided**

## 7. Closures and defer

**Closures.** A closure captures each name with a sigil:

- `?x` borrows `x` for the closure's life;
- `!x` borrows it to write;
- `<x` moves it in;
- `+x` captures a new owner.

A stack closure may be lent (`?fun`) but not stored. An owned closure
(`*fun`) may be stored, and follows sentence 9. **built**

**Defer.** `defer` and `errdefer` run where their scope ends. They may read
and write what is live there; they never extend a loan past it. **built**
(hotfix B1)

## 8. Outside the core: syntax, not ownership

These are single documented syntax rules, not ownership:

- **`-x`:** as a statement, `-name` drops; as a value, `-x` negates.
  A statement `-f()` is rejected (fix B5).
- **The receiver-sigil rule:** `!v.push(x)` applies `!` to `v`. **built**
- **`const x = e`**: a binding that never changes (today `=!`). **decided**
- **A write call whose `Bool` value is used** is written
  `(!s).insert(k)`, everywhere. **decided**
- **Labels**, the `catch` forms, `pass`, and `??`.
- **Habits from other languages that keep Rig's meaning,** documented
  rather than changed:
  - integer `/` and `%` truncate as in C;
  - `u?.n` propagates `none` from the function;
  - `break` inside a `match` leaves the loop;
  - `e catch a if c else b` groups as `e catch (a if c else b)`.

## 9. Inside the compiler (not user-visible)

**Per type, one fact each:**

- copyable;
- unique;
- needs cleanup;
- may hold a borrow;
- cloneable;
- how a read borrow is represented (a copy, or a pointer).

**Per expression, one classification:** what it hands over.

- a place;
- a made value;
- a lend;
- a view;
- branches;
- a jump.

This includes whether the value lives for the whole program.

**Per path, one exit primitive.** It runs defers, reports any loan it would
drop, and rewinds when the path goes on.

No pass decides these facts again by looking at syntax. **decided**

## 10. How a feature earns its way in

- It fits one paragraph on this page, with no exception list.
- Its rules follow the value's type, never where the value came from.
- It is written as a desugaring into forms this page already covers.
- A second round of soundness fixes stops it for redesign.
- It passes the regression corpus, and runs clean under the sanitizer.
- It answers a line that failed in a real program, not parity with Rust or
  Zig.

---

## Decisions (settled 2026-10-02)

1. A move-only type that owns nothing is written `struct Rng unique`.
2. A type holding a `Cell`, or a bare `Cell[T]`, is `unique` (not copyable).
3. An error value meets `T!` only as the operand of `return`.
4. Assigning a borrow to a borrow place re-points; assigning a value writes
   through; locals and fields alike.
5. A binding that never changes is `const x = e` (replaces `=!`).
6. A write call whose `Bool` value is used is written `(!s).insert(k)`.
7. Returning an owner, or ending a function or block with one, moves it;
   so does `break x`.

Corrections, not choices: `??` is not a failure handler; `print` copies a
plain argument when it reads it, left to right, as Python, JavaScript, and
Rust do.
