Rig 0.2.0 is the consolidation release.

Before 0.2.0, Rig stayed sound by review: each round caught holes in the ownership checker. Now soundness is a property of how the compiler is built:
- **One decision per fact.** Every fact about ownership is decided once and recorded, and the ownership checker and the code generator read the same records.
- **Hidden storage is recorded.** Every temporary or copy the generated code makes is a recorded fact that the checker walks.
- **An independent second checker cross-checks the tests.** The reference checker shares no code with the compiler. The suite fails if the compiler accepts a program it rejects.

The language reference now follows Rig's ten-sentence ownership core (docs/CORE.md), and every example in it is run by the test suite.

## New in the language

- **Containers hold anything.** For example `Vec[Text]`, `Vec[Vec[Int]]`, arrays of boxes, records that own text, and Vecs of views. Every element is a place: `?v[i]`, `!v[i]`, `<v[i]`, and `v[i] = x` drops the old value exactly once.
- **`+x` clones deeply.** It copies Vecs, boxes and structs that own other values, recursive types included.
- **A write view can be re-pointed:** `w = !n`.
- **No lifetime annotations by default.** A result views only the arguments whose types could hold it. `-> T from a`, `from self` and `from static` say exactly which, and the compiler checks the body against it. In std, `strip_prefix`, `strip_suffix` and `cut` declare `from s`, and `os.env` declares `from static`.
- **Implicit read lends.** `size(v)` lends `v` to read where the parameter is a view. Write lends are always written.
- **Branching receivers keep both loans.** In `(a if c else b).inner()` the result keeps a loan on each branch, and a Cell change on such a receiver lands in the branch taken.
- **One vocabulary.** Diagnostics say *lend* (the act), *view* (the value) and *loan* (the record). A note teaches that a `String` views text it doesn't own.

## Breaking changes

Each item lists, in parentheses, how many of v0.1.6's own test and corpus programs it affects (from a survey of them).

1. **`x =! e` is gone.** Write `const x = e` (46 programs).
2. **An error value meets `T!` only as `return`'s operand.** Write `return E.bad` (16).
3. **`std.random.Rng` is renamed `Random`,** and it is `unique` (15).
4. **A write call whose `Bool` result is used** must be written `(!s).insert(k)` (8).
5. **A type holding a `Cell` is `unique`,** so a bare copy needs `<c` (6). `print` now shows a Cell's current value.
6. **Read-`match` payload views are usable within their arm only, for now.** For example, `.a(t) => return ?t` with `match ?e` ran on v0.1.6 and is now rejected. Emit may match a copy of the subject; B4 lifts this.
7. **A `match`, `if … as`, `while … as` or `for` header whose subject makes a statement temporary is rejected.** The hint is "bind the index (the argument) to a name first". v0.1.6 already rejects most of these forms.
8. **An unused `match` payload binding is an error** (5).
9. **Writing through a write view held in a read-`match` payload is rejected** (1).
10. **A `!self` method called on a temporary is rejected** (`mk().bump()`). Every change is marked by `!`, and a temporary can't be lent to write.
11. **Behaviour change (not a rejection):** `w = f(!n)` with no type now holds the write view, so `w = 5` writes `n`, as CORE §6 says. Before, it silently wrote a copy.

**Rejected by v0.1.6, sound and accepted now:**
- containers of owners (`Vec[Text]`, `Vec[Vec[Int]]`);
- element places;
- `+x` of Vecs, boxes and owning structs;
- re-pointing write views;
- `from`;
- branching receivers: `(a if c else b).inner()` keeps both loans, and a Cell change lands in the branch taken.

In all, 185 of v0.1.6's programs go from rejected to accepted.


## Verification

All under the sanitizing allocator, which now also poisons hidden stack storage when it dies:
- **Test suite:** 2,608 tests pass.
- **Reviewer probes:** 6,021 probes, kept from every review round, pass.
- **Program matrix:** 3,070 form × context × type programs, 0 failures.
- **Unit tests** pass.
- **Reference checker:** it decides over 35,000 functions across the test sets and has never rejected a program the compiler accepts.

An independent final review checked every Core sentence against the compiler with about 210 adversarial programs and found no critical or high issue. CI passed on Linux and macOS.

## Requirements

Zig 0.17.0. Nexus 2.0.0 is needed only to change the grammar.

Full change: #50 (consolidation), #51 (version).
