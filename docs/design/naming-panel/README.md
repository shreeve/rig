# Naming panel

Four seats chose what Rig calls the named sets of methods a type
provides, and how they are written. Three each brought one design
philosophy, written in its spirit and not as a claim to speak for
anyone: Ruby's programmer happiness and least surprise, CoffeeScript's
minimalism, and Swift's protocol-oriented design and its lessons. A
fourth, a plain-English critic, settled where they differed. Each
report is kept as written. All four ranked `role` first; the owner
chose `api`, which none of them had ranked, and the decisions below
hold over the reports.

| Report | Seat |
|---|---|
| [1-least-surprise.md](1-least-surprise.md) | programmer happiness and least surprise |
| [2-minimalist.md](2-minimalist.md) | minimalism: the least that stays unambiguous |
| [3-protocols.md](3-protocols.md) | protocol-oriented design |
| [4-plain-english.md](4-plain-english.md) | a plain-English critic |

## Decisions

1. The word is `api`: `api Shape` declares the methods a type provides,
   not their implementation. A type provides an API on its header,
   `obj Square: Shape`.
2. `+` joins APIs in headers, bounds, and braces.
3. `extend Int: Shape` provides an API for a type one does not own; its
   methods stay inside it and need no `pub`.
4. Methods on a type's header that meet a `pub` API on a `pub` type say
   `pub`.
5. Every default may be overridden; a method with a default's name and
   another signature is an error.
6. The built-in APIs keep short names, and errors about them say what
   cannot be done: "`Label` cannot be hashed".
7. `{Iter[Item: Int]}` is kept free, and a bare API name in a type is
   an error.
8. `api` and `extend` are keywords only at the start of a declaration;
   `trait` and `impl` stay reserved to point to them.
9. A later feature of preconditions and postconditions is spelled
   `requires` and `ensures`.
10. No spelling yet for calling a default from an override, and the
    `Iter` methods built on `next` (`map`, `filter`, ...) are a later
    std decision.
