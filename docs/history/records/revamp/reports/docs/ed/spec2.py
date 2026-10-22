E = []
E.append((r'''does not fit the target type panics when the program runs, and so does
a float whose integer part does not fit; a float becomes an integer by
truncating toward zero,''', r'''does not fit the target type panics when the program runs, and so does
a float whose integer part does not fit, or a NaN; a float becomes an
integer by truncating toward zero,'''))
E.append((r'''built with it. `xs.len` is an array's length, and `xs[i]` reads or
writes an element; an index outside''', r'''built with it. `xs.len` is an array's length, and `xs[i]` reads or
writes an element, with an index of any integer type; an index outside'''))
E.append((r'''function, for the arrays it makes and, for a type, for itself. The
values a function keeps''', r'''function, for the arrays it makes and, for a type, for itself. A
`Cell` or `Signal` holds its value inline, so it counts at the size of
what it holds. The values a function keeps'''))
E.append((r'''A program that runs off the end of its stack stops before it writes
beyond it. On x86_64, Zig touches each page of a new frame in turn,
so any frame stops at the guard page below the stack. On aarch64 it
does not, and a frame steps as far below the stack as its size: at
most 16 MiB of counted values, plus Zig's own temporaries. At least
64 MiB below the stack stays unmapped, four times the counted limit,
so every overflowing frame lands there: on macOS the program reserves
it when it starts; Linux maps nothing within 128 MiB of the top of the
stack, and the program holds its stack to 16 MiB. A program that
cannot do so stops before it runs, with `rig: cannot reserve the stack
guard below the main stack` and exit status 1.''', r'''A program that runs off the end of its stack, by recursing too deeply,
stops before it writes beyond it. A program that cannot set up the
guard that ensures this stops before it runs, with `rig: cannot reserve
the stack guard below the main stack` and exit status 1
([INTERNALS](docs/INTERNALS.md) describes the mechanism).'''))
E.append((r'''The handle sigils `*` and `~` bind to the type after them, tighter than
the suffixes: `*User?` is an optional shared handle and `~User?` an
optional weak handle, while a handle to an optional `User` is written
`*(User?)`. A borrow applies to the whole type after it, suffixes
included: `?User?` and `!User?` borrow an optional `User`, and
`?*User?` borrows an optional handle. The element of a slice or array
takes the suffixes (`[]Int?` is a slice of optionals), so an optional
slice, array, or function type is written in parentheses: `([]Int)?`,
`(*sub())?`, and so is an optional of an optional, `(User?)?` (`??` is
an operator). A handle holds a value, never a borrow: `*(?User)` is
rejected. Prefixes compose right to left: `?*Wrap` is a read borrow
of a shared handle, and `*Cell[Vec[*sub()]]` is a shared cell holding a
list of owned closures.

```rig
struct User
  name: String

fun named(u: ?*User?) -> Bool
  u != none

sub main
  a: *User? = none
  b: *User? = *User(name: "ada")
  print(named(?a), named(?b))
```

```output
false true
```

```rig reject
struct User
  name: String

sub main
  c: *(User?) = none
```

```error
`none` needs an optional type; `*(User?)` is not optional (write `*(User?)?`)
```
''', r'''How the sigils of a type combine (`*User?` is an optional handle,
`?User?` a borrow of an optional) is in
[SYNTAX §7](SYNTAX.md#7-types). A handle holds a value, never a
borrow: `*(?User)` is rejected.
'''))
E.append((r'''A **Copy** value is plain data: numbers, `Bool`, `String`, plain enums,
arrays of Copy values, and structs whose fields are all Copy. Using one
copies it.

An **owning** value holds a resource that must be released exactly
once: a `*T` or `~T` handle, a `Vec`, a `Signal`, an owned closure, and
any struct, enum, or generic instance that contains one or declares a
`drop` body.''', r'''A **Copy** value is plain data: numbers, `Bool`, `String`, plain enums,
and optionals, arrays, structs, and `Cell`s that hold only Copy values.
Using one copies it.

An **owning** value holds a resource that must be released exactly
once: a `*T` or `~T` handle, a `Vec`, a `Box`, a `Signal`, an owned
closure, and any struct, enum, or generic instance that contains one or
declares a `drop` body.'''))
