# Named options for Rig: the consensus

From: the keyword-only panel (`../kwonly/designer.md`, `evangelist.md`,
`practitioner.md`), the options committee (`innovator.md`, `zig.md`, `rig.md`),
an outside review the owner shared, and two red teams (`redteam-design.md`,
`redteam-code.md`). Every reviewer: sound with fixes; nothing fatal.

## The proposal

```rig
fun connect(host: ?String, port: Int, timeout: Int = 30, retry: Bool = true) -> Conn!
connect(host, 5432, timeout: 5)          # 1. a default makes an option; options are named

obj Net                                  # 2. a group: options shared by many functions
  timeout: Duration? = none
  retries: Int = 3
fun fetch(url: ?String, ..net: Net) -> Response!
fetch(url, retries: 5)                   #    name its fields directly,
fetch(url, ..cfg.net)                    # 3. or spread a stored value whole
fetch(url, retries: 9, ..cfg.net)        #    named fields win; the spread fills the rest

q = Point(x: 3, ..p)                     # 4. the same spread updates an object
fetch(url, retries:)                     # 5. shorthand: retries: means retries: retries
```

1. **The rule.** Required values come first, by position. Options (parameters
   with a default) are given by name. A trailing closure fills its callback
   parameter. No exemption for the first parameter.
2. **Groups.** An object type used as `..net: Net` makes its fields name-only
   options of that function; the body sees `net`. The compiler rewrites the
   signature into plain parameters.
3. **Spreads.** `..v` supplies a value's fields. Nominal only: `v`'s type must
   be the group's type. A value is complete (making one fills every default).
   Named fields written beside a spread win, in any order; one spread per group.
4. **Object update.** `Point(x: 3, ..p)`, same rules.
5. **Shorthand** `name:` for `name: name`, ended by `,` or `)` on the same line.

## v1 limits (each can be lifted later without breaking programs)

- Groups and object update hold plain values only (no owners, no read views).
- A function with options can't be taken as a value; write a closure. (Today
  defaults pass by position through a value, which a group would make a silent
  field-order dependency.)
- Unit keywords (`ms:`, `seconds:`) never fill a group field.
- A wrapper can't override a field of the group it received.
- No spreads into calls whose arguments are checked at compile time (`round`,
  `floor`); they keep inline units.
- Deferred: `f.Options` (a function's options as a type), groups in APIs,
  function values that keep their options, generic groups, pointer-passed groups.

## Performance

The language promises: **no run-time lookup or machinery; every call lowers to
the same code you would write by hand.** The base rule leaves emitted Zig
byte-identical. A spread becomes plain field reads as arguments. How a group is
passed (separate arguments or one struct) is the compiler's measured choice, not
a language rule: on the probes, separate arguments were a bare tail call and a
40-byte struct cost a stack frame and a copy, so groups start as separate
arguments. Compile time: an extra check round, about 4 ms per 65 KB module.
