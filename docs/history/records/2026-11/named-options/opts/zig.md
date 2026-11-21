# Options at the call: the Zig and systems review

Read: the brief; `innovator.md` and its probes in `inn/`; Rig main 75a6c7b5e
SPEC Functions (1595-1660: defaults are a literal or a module constant, filled
at the call), `docs/CORE.md` (owners, partial moves, drop points),
`sema.ArgCheck` and `typecheck.zig` `stdArgChecks` (12500-12730). Probes in
`zig/` beside this file (`abi2.zig`, `abi3.zig`, and their `.s`), built with
Zig 0.17.0, `-O ReleaseFast`, for aarch64-macos and x86_64-linux.

## Verdict

The language side of the innovator's design is right, and right-sized: one
spelling, `..`, in three places (a parameter, an argument, a function type);
nominal spread, never structural; spread before overrides; punning for the
construction lines that dominate Trig. I'd keep all of it.

The systems side has one wrong claim and three fixable gaps:

1. **"A group costs what the separate arguments cost" is false** for a call
   Zig does not inline. Measured below: a 40-byte group is built in a stack
   slot and passed by pointer; a stored group is copied first. The fix is a
   lowering rule, not a language change: **a group lowers flat**, one Zig
   parameter per field, and `..o: ?T` is the explicit by-pointer form.
2. **The thunk for function values disappears** under that rule: every way of
   declaring options has one ABI, so a function value is the function itself.
3. **Owners in a group** bring `..<v`, `..+v`, and a hidden drop on override.
   Leave them out of groups: options are plain values and read views, as
   Zig's options structs in std are.
4. **`round(..s: Step)` breaks a compile-time guarantee.** `ArgCheck` counts
   keywords at the call ("exactly one unit"); a spread of a stored `Step`
   gives it nothing to count. `Step` must not be a group.

And one simplification: **`f.Options` is the function's implicit group**, the
type of its inline options, always, which removes the "only when all inline"
restriction and makes inline and declared options one concept.

## 1. What Zig 0.17 actually does with an options struct

`abi2.zig`: the same body taking `(url, timeout, retries, follow, name)` flat
or `(url, net: Net)` with `Net` 40 bytes, both `noinline`, called with
runtime values (constants let LLVM specialize the callee and hide the ABI).

| Call | aarch64 | x86-64 |
|---|---|---|
| flat, values in registers | tail jump `b flat`, 0 extra instructions | `jmp flat` |
| flat, spread from a stored value (`net.f` each) | 3 load pairs, tail jump, no frame | 5 loads, 1 spill (7th arg), call |
| group from keywords `.{ ... }` | 64-byte frame, 3 stores, `add x2, sp`, `bl` | 48-byte frame, 5 stores, `lea`, call |
| group spread from a stored value | frame, **40-byte copy** (q-reg pair + x), `bl` | frame, 40-byte copy, call |
| callee reading the group | 3 loads from `[x2]` | 5 memory operands |
| view group `*const Net`, stored value (`abi3`) | pointer forwarded, tail jump | (same) |

So Zig's "auto" calling convention in 0.17 passes a large struct the way the
C ABI does: a caller-owned copy and a pointer. It does **not** reuse the
caller's storage (the old parameter-reference optimization, which Zig backed
away from because of aliasing bugs, ziglang/zig#5973). Inlining erases all of
this (SROA scalarizes the struct), but a function big enough to stay a call is
exactly where the copy shows. A few nanoseconds, never a regression that
matters, but the brief asks for zero cost and the innovator asserted it.

Flat lowering is zero cost by construction: a spread is field reads into
argument registers; keywords are immediates. A group of more than about 8
register-sized fields spills to the stack, which is what the struct copy
costs anyway, and the author who has a large group writes `..o: ?Net` to pass
one pointer (measured: forwarded with no copy).

## 2. The design I'd ship

```rig
# Options: parameters with defaults, by name (the panel's rule). They form
# the function's implicit group, whose type is connect.Options.
fun connect(host: ?String, port: Int, timeout: Int = 30, retry: Bool = true) -> Conn!

# A declared group: `..name: T` takes T's fields as options.
obj Net
  timeout: Duration? = none
  retries: Int = 3
  follow: Bool = true
fun fetch(url: ?String, ..net: Net) -> Response!
fun mirror(url: ?String, ..net: ?Net) -> Response!   # by view: one pointer

o = connect.Options(timeout: 5)
connect(host, 5432, ..o, retry: false)    # spread, then override
fetch(url, ..cfg.net, follow: false)
fun connect_logged(host: ?String, port: Int, ..o: connect.Options) -> Conn!
  connect(host, port, ..o)                # forwards every option, present and future

q = Point(..p, x: 3)                      # struct update, same rule
Mapping(generated_position:, source_index:)   # punning
```

Lowering, all of it:

```zig
pub const connect__Options = struct { timeout: i64 = 30, retry: bool = true }; // only if named
pub fn connect(host: []const u8, port: i64, timeout: i64, retry: bool) !Conn { ... }
pub fn fetch(url: []const u8, net_timeout: ?Duration, net_retries: i64, net_follow: bool) !Response {
    const net: Net = .{ .timeout = net_timeout, .retries = net_retries, .follow = net_follow }; // only if `net` is used whole
    ...
}
pub fn mirror(url: []const u8, net: *const Net) !Response { ... }
pub fn connect_logged(host: []const u8, port: i64, o_timeout: i64, o_retry: bool) !Conn {
    return connect(host, port, o_timeout, o_retry);
}
// connect(host, 5432, ..o, retry: false)
connect(host, 5432, o.timeout, false)
// fetch(url, ..cfg.net, follow: false)
fetch(url, cfg.net.timeout, cfg.net.retries, false)
// mirror(url, retries: 5): a temporary the call views
mirror(url, &.{ .retries = 5 })
```

Rules, beyond the innovator's:

- **One ABI per group type.** A group of type `T`, inline or declared, lowers
  to `T`'s fields as consecutive parameters; `?T` lowers to `*const T`. In the
  body, the group's name is a local struct built from those parameters only
  when it is used whole (stored, returned, passed to a `?T`); reading
  `net.timeout` is the parameter. Zig's SROA makes even that construction free.
- **Function values need no thunk.** `connect` as a value has type
  `fun(?String, Int, ..connect.Options) -> Conn!`, lowering to
  `*const fn ([]const u8, i64, i64, bool) anyerror!Conn`. A call through the
  value fills omitted options from the group type's defaults, which are
  constants by SPEC, at the call, exactly as a direct call does.
  `connect_logged` has the same Zig type, so both fit one value. The
  innovator's thunk existed only because inline and declared groups lowered
  differently; with one ABI it goes, with its extra indirect jump.
- **Groups hold no owners.** A group's fields are plain values and read
  views (`?String`, `?List[T]`). Spreading one is then always a copy of
  scalars and fat pointers, never a move or a clone, and an override drops
  nothing. This removes `..<v` and `..+v` from the options story (about 100
  lines of ownership work) and the question "does an override run a `drop`
  body?", which would be an effect hidden in a call's argument list. An owner
  the callee keeps is an operand, passed by position with `<`. Zig's own
  option structs (`std.http.Client.FetchOptions`, `std.process.Child`'s
  fields) are borrowed slices and plain values for the same reason.
- **Struct update keeps owners, by partial move.** `Point(..<p, name: n)` on
  an ordinary object moves the fields it takes out of `p`; `p.name` stays in
  `p` and drops at `p`'s drop point, by the partial-move rule Rig already has
  (CORE.md, Drop points). So no new drop appears at the expression. A plain
  `..p` of an object with owners is refused, as the innovator says.
- **`f.Options` is always the implicit group**, the type of `f`'s inline
  options, whether or not `f` also declares groups. `fun with(?@, strict:
  Bool = false, ..date: DateFields)`: `with.Options` has `strict`; the date
  group is `DateFields`. No nesting, no restriction. Refused only for a
  function with no inline options.
- **A spread may not feed a parameter `ArgCheck` guards.** Today
  `round(minutes: 15)` is checked at compile time for "exactly one unit" and,
  for constants, the increment's range. A spread of a runtime value can't be
  checked that way, so a program the compiler accepts could be wrong, the
  North Star's one line. In the datetime library: `Period`, `DateFields`,
  `ClockFields` as groups are fine (any combination is valid, and a `Date`
  taking `..p: Period` refuses duration units by type, which retires part of
  `calendar_add`); **`Step` is not a group**, and `round`/`floor` keep their
  inline units. A stored rounding step is a `Duration`, and if that is
  wanted, `round(by: Duration)` with a runtime check is its own decision.

## 3. Cost and size, against the innovator's table

| Area | Innovator | This | Why |
|---|---|---|---|
| ownership | ~150 | ~40 | no owners in groups; struct update reuses partial moves |
| emit | ~200 | ~180 | no thunk; flat group params and the lazy local struct instead of literals |
| typecheck | ~600 | ~560 | one ABI, so calls through values are the direct-call path |
| sema | ~200 | ~180 | `f.Options` always defined, no restriction to check |
| parser | ~120 | ~120 | same syntax |

About 1.1k lines in all, same stages. Stage order unchanged: base rule;
spread + struct update + punning; groups; `f.Options`; function values (now
cheap enough to ship with groups).

## 4. Where it sits among the precedents, at the machine level

- **Zig** `f(a, .{ .x = 1 })`: one struct parameter; copy plus pointer when
  not inlined (measured). Rig's keywords give Zig's call-site readability with
  C's flat ABI, and `?T` gives Zig's struct-by-pointer when the author wants it.
- **C designated initializers** `f(a, (Opts){ .x = 1 })`: same as Zig, by the
  SysV/AAPCS rules (> 16 bytes: memory). No defaults, no partial override.
- **Rust** `..Default::default()` and builders: struct update compiles to
  field moves, zero cost; a builder is zero cost only after inlining and its
  `build()` often allocates or validates at run time. Rig's struct update is
  Rust's, with base first.
- **Swift/Kotlin** default arguments: Swift emits a default-argument
  generator function called at the site; Kotlin emits a `$default` synthetic
  with a bitmask parameter, a real branch per option at run time. Rig fills
  constants at the site: cheaper than both.
- **C#** optional parameters bake defaults into callers, so changing a
  library's default needs callers rebuilt. Rig does the same, harmless while
  Rig compiles whole programs; note it if separate compilation ever arrives.
- **Odin** named arguments and **Jai** named arguments: flat, compile-time
  only, zero cost, but no value form. This design is Odin's call plus a value.
- **Python/Ruby/JS** dictionaries and objects: allocation and hashing per
  call. Refused.

## 5. What I'd leave out

- **Struct parameters as the group's ABI** (the innovator's lowering): the
  copy and pointer above, and a thunk to bridge it.
- **Owners in groups**, and with them `..<v` and `..+v` for options.
- **Spreads into `ArgCheck`ed calls**, and a `Step` group.
- Everything the innovator already leaves out (structural spread, open bags,
  anonymous literals, builders, generic "options of F"): agreed. The anonymous
  literal especially: target-typed `.{}` is what forces Zig's struct ABI, and
  Rig's keywords already are the literal.

## 6. Two sentences

A parameter with a default is an option, given by name; a function's options
form a value (`f.Options`, or the type of a `..name: T` parameter), and `..v`
passes a value's fields with names after it overriding them. It compiles to
one plain call with every option a separate argument, unless the group is
written `?T`, which passes one pointer.
