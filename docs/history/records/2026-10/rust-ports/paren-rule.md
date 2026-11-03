# Design note: `(!x)` only where the result is a `Bool` (2026-10-29)

**Status:** built (#772): a write call whose value is used is written
short, and only a `Bool` keeps its parentheses.

From Rig - Rust, after the owner asked whether the `(!x)` parentheses
could go.

## The owner's words
> "Could we replace (!x) with just !x, is will this create a lot of confusion???"
>
> "Do you recommend we make the switch to ONLY using (!x) in those few cases that need it?"

Rig - Rust recommended yes. The owner then said to send it to Rig - Swiss
to share with Rig - Merges (fork) and Rig - Merges. He has not yet said
in so many words "approved, build it": confirm with him before it lands.

## The rule today
A write call whose value is used puts its `!` in parentheses everywhere:
`x = (!v).pop()`, `if (!s).insert(k)`. The short form `!v.pop()` stands
only as a statement (SYNTAX §8 "Self sigils", DESIGN, CORE's syntax-rules
list, Learn 01). The only stated reason is "so that its `!` never reads as
negation". The short form already parses: `x = !v.pop() ?? 0` is rejected
by one check, `src/typecheck.zig:15174`.

## What the parentheses guard, measured on Trig
Of 18,717 `(!x).m(...)` uses in Trig:

| Context | Uses | Could `!` read as "not"? |
|---|---|---|
| bindings and arguments: `t = (!@).new_node(...)` | ~11,800 | no: the result is a node, a type, or a list |
| `if`/`while ... as x` | 214 | hardly |
| `if`/`while` on a `Bool` result: `if (!@).is_matching_reference(r, n)` | ~1,300 | **yes**: the short form reads as the opposite |
| `not (!x).m()` | 384 | it would read as a double negative |

**The trap:** Rust's `if !seen.insert(k) { continue }` means "already seen".
Ported as is to a Rig with the short form everywhere, it would compile and
mean the opposite. An AI porting Rust writes exactly that.

## The proposed rule
> A write call is written `!v.pop()`. When its value is a `Bool` and is
> used, the `!` goes in parentheses, `(!s).insert(k)`, so it never reads as
> "not".

- **Decided by the declared result type.** A generic call returning `T` is
  never forced into parentheses, even when `T` is `Bool`.
- **The long form stays valid everywhere,** as it is today.
- **The message on the `Bool` case:** ``write `(!s).insert(k)`: a write
  call whose `Bool` value is used puts its `!` in parentheses, so it never
  reads as `not` ``.

## Effect
- **Nothing breaks:** it only accepts programs rejected today, so Trig needs
  no migration. An optional script can drop the ~15,000 parentheses that are
  no longer needed.
- **What it removes:** the parentheses go from about 93% of uses, where they
  are pure noise.
- **What it keeps:** the guard on the ~7% where it matters.
- **A side benefit:** the parentheses now carry information, namely that the
  result is a truth value.

## The change
- **Checker:** narrow the check in `src/typecheck.zig` to calls whose
  declared result is `Bool`.
- **Cases:**
  - the short form accepted in a binding, an argument, an `as` header, and
    under `??`;
  - the short form rejected on a `Bool`, including the `insert` trap and
    `not !x.m()`;
  - a generic `T` result accepted;
  - a `code` case showing the emit is unchanged.
- **Docs:** QUICK, Learn 01, SYNTAX §8 (the table and the paragraph after it),
  DESIGN, CORE's syntax-rules list, SPEC §3 where it states the rule, and
  CHANGELOG.
- **Sequence:** after errors-only, as the next language change; one feature
  in flight at a time.
