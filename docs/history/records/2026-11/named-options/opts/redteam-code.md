# Red team, code side: the options design against Rig's compiler

Rig main 75a6c7b5e. Probes are in `rc/` beside this file (t1-t21), run with
`bin/rig run`. Read: `modules.zig` check loop (870-880), `typecheck.zig`
`chainCall` (15993), `checkArgs` duration paths (11949-12210),
`stdArgChecks` and its checks (12505-12620), `sema.zig` `ArgSlot`,
`ParamMask`, `Origins`, `CallParams` (3009-3200), `exprKey` (1859),
`rig.zig` `HiddenName` (2723), `hiddenLeaf`/`hiddenPos`/`leafText`
(2952-3030, 5960), `desugarChains` (5676), `ownership.zig` body-vs-signature
check (7320-7430), `storage.zig` `planHeldHeaders` (1676), `emit.zig`
`emitArgsFrom` (9868), `emitDefault` (10052), param walks (1988-2144),
`rig.grammar` `open`/`callarg` (1367-1406), CORE §4-§5.

## What holds (verified)

- **Evaluation order.** Keywords out of order are hoisted in written order
  (p1 emits `__rig_arg_1_0 = x` before `bump(&x)`). A field read before a
  later `!o` in the same call is copied first (t3: `connect(1, t: o.t, r:
  bump(!o))` gives 6, then `o.t` is 105). A read-view field read before a
  write of its holder is fine (t4). So a spread placed at its written
  position keeps today's order.
- **Punning never hides a move.** `take(s: s)` of an owner is refused with
  "write `<s` ... or `+s`" (t16); `look(s: s)` to a `?String` is a view.
- **Partial moves** work from locals and by-value parameters (p10, t17).
- **Read-view options are sound in the flat form**: `mk(name: ?s)` whose
  result outlives `s` is refused (t19).
- **Parameters are immutable** (t12), so group fields as parameters stay
  immutable.
- **Compile time** of the extra round is small: `std/json.rig` (65 KB)
  typechecks in about 4 ms.
- **Run time**: a spread is field reads at the call, the same as writing
  the keywords. Zero relative to hand-written flat parameters. (Not relative
  to Zig's by-pointer struct for a large group forwarded through layers:
  past 8 integer registers on aarch64 a flat group spills to the stack. A
  Duration takes two. Minor.)

The brief's phrase "a rewrite before checking" is not what rig.md says nor
what the precedent does: the module is typed once (the spread recorded,
the call given no type, as `chainCall` gives `unknown`), rewritten, and
checked again. So `checkArgs` must still accept a spread in round 1 and stay
quiet about it.

## Findings

### 1. The chain mechanism cannot build a spread's nodes (serious: cost)

The round loop is reusable; the node building is not. A rewrite's
synthesized names are a fixed enum, `HiddenName` (rig.zig 2723): 27 named
texts plus 3 per chain stage, 256 ids in all, asserted full enough
(`first_stage + stage_texts.len <= 0x100`). `leafText` (3025), which "every
pass reads a name through", returns either source text at the leaf's
position or that enum's text. A spread needs a keyword-name leaf and a
member-name leaf with **arbitrary** text, a field name usually declared in
another module's source (`Period.months`, `Net.timeout`). Neither form of
leaf can hold that.

Positions are a second constraint. Leaf facts are keyed by position
(`exprKey`: `.src => s.pos`). Reusing the real `o` leaf of `..o` for N
`o.f` nodes gives N uses one fact key. Hidden positions (`hiddenPos`, past
the source's end, homed by `pad_homes`) fix the key but have no text but the
enum's. The iterator rewrite's comment states the invariant: a synthesized
leaf sits "at a position ... which no other leaf has".

Fix: budget a synthesized-name leaf kind (an id range, a per-module name
table `leafText` can reach, positions from `hiddenPos`), or carry the
spread as its own IR node that the matcher expands virtually. That is about
150-300 more lines, plus round-2 messages: `sourceText` of a synthesized
node prints its span, `..o`, so "given twice" and type errors need rewording.

### 2. Groups "flattened in sema" misalign ownership, storage and emit (serious: claim false, risk of unsound)

rig.md flattens `..net: Net` "in the signature, in sema" and keeps
`ArgSlot`/loans unchanged. But the declaration side of three passes indexes
the **function type's** `ParamMask` bits by the **IR parameter list**:

- ownership's body check of `from`/`keeps` (7337-7366):
  `paramBit(i)` against `items[i]` and `paramNameNode(items[i])`;
  `paramList`, `namesStatic` (7400-7430) the same;
- storage `planHeldHeaders` (1691) walks IR params for their symbols;
- emit (1988-2144) finds each parameter's local by `paramNameNode`.

With one IR node `..net: Net` standing for k type parameters, every bit
after it names the wrong parameter. At best the messages name the wrong
parameter. At worst a `keeps` or `from` check reads another parameter's bit.
And `from net` / `keeps net` have no meaning yet when the group holds read
views: `net` is a body local, not a parameter, and the body local is
"built ... and its emit", invisible to ownership unless it is real IR.

Fix: rewrite the signature in the IR, not just the type: k name-only param
nodes and a real body binding. That needs finding 1's leaves. Or change those
passes. Either way "none in ownership, storage or emit" does not hold for
groups. Simplest safe v1: **groups hold plain values only** (no read views),
so `from`/`keeps` never name a group field. Re-estimate groups at ~600-800
lines, not 400.

### 3. `..<p` "each field with the spread's sigil" is refused for nearly every type (serious: spec bug)

- t1: `P(a: <p.a, n: <p.n)` gives "cannot move out of `p.n`: it copies, so
  `<` would leave it as it was". Any copy field refuses the literal rewrite.
- t2: a type with a `drop` body refuses partial moves outright ("`P` has a
  `drop` body, which expects every field").
- `<p.f` on an optional field takes it and leaves `none` (CORE §5), a
  different meaning per field type.

Fix: type-directed. `<` goes only on fields that move, copies are copied,
and the CORE paragraph says so. Document that struct update of a `drop`
type is `..+p` or a whole move. (`+p.n` on an Int is accepted, t5.)

### 4. Spread-first order refuses the natural update (serious: a sensible program refused)

`P(..<p, n: size(?p))` rewrites to `P(a: <p.a, b: <p.b, n: size(?p))`,
refused: "`p` is partly moved" (t20). Written keyword-first,
`P(n: size(?p), a: <p.a, b: <p.b)` builds (t21), but rig.md makes "a keyword
before a spread" an error ("given twice"). Rust evaluates `..base` last for
exactly this reason.

Fix: a spread fills the fields not named anywhere in the call, and may stand
last; it is evaluated where written. "Given twice" is then only two spreads
covering one field.

### 5. Function values make group field order a silent positional contract (serious: North Star 1)

Today a function with defaults taken as a value is called positionally,
options included: `g = connect; g(1, 2, 3)` gives 123, and so does
`run(connect)` (t14). Under the base rule this already contradicts "options
by name". Under groups the positional order of `fetch`'s value type is the
**field order of `Net`**, declared elsewhere, maybe in a library, where order
means nothing to any other use. Swapping two `Int` fields (`retries`,
`redirects`) silently swaps arguments for every caller through a value: an
accepted, wrong program. This is the C# and Scala pitfall.

Fix: in v1, refuse a function with options (inline or grouped) as a value.
Wrap it in a closure that names them. Or make function types carry names.

### 6. Adding a field to a group is not compatible (serious: evolution claim)

- **Durations.** A unit keyword fills "the callee's one duration
  parameter"; with two, `checkArgs` refuses: "`f` takes 2 durations, so each
  is given by its own name" (typecheck 12138). Adding
  `connect_timeout: Duration?` to a shared `Net` breaks every `fetch(url, ms:
  500)` in every function that uses `Net`.
- **Collisions** are refused at the declaration, so a library adding
  `retries` to `Net` breaks a user's `fun f(x, retries: Int = 0, ..n:
  lib.Net)` or `fun g(..a: lib.Net, ..b: lib.Tls)`. That is JavaScript
  spread's coupling, moved to compile time.

Fix: say it in the design. Consider giving group Duration fields by name
only (no unit keyword), which keeps adding a Duration compatible.

### 7. Field defaults and parameter defaults differ (minor)

An object field accepts `T()`, `List()`, `String()`, `Cell(0)` as its default
(t10, and t6's message). A parameter refuses anything but "a literal, a
module constant, or a number type's limit" (t8 `Inner()`, t9 `List()`). A
plain-value group `tls: Tls = Tls()` flattens into a default the parameter
rule refuses. `emitDefault` has a `field` mode that may cover the
emission. Fix: refuse such group types in v1, or widen the parameter rule
on purpose.

### 8. Smaller inaccuracies (minor)

- "`ParamMask` ... refuse past 64 as today": nothing is refused today. A
  parameter past bit 63 is "in every set" (sema 3049-3056): conservative,
  imprecise. Flattening only makes that more likely.
- "`..x` in `( )` ... told apart by the bracket, as Rust does": in Rust,
  `f(..x)` is a `RangeTo`; Rust tells struct update apart by braces. Rig's
  syntax is free anyway: an open-start `..b` parses only inside `[ ]`
  (rig.grammar 1367-1372).
- `fun f(..o: f.Options)` and mutual `f`/`g` group cycles are unspecified.
  So is whether `connect_logged.Options` *is* `connect.Options` when its
  only options are that group. Nominal spreads make that difference visible.
- "Two sentences": a group field without a default is a required name-only
  argument, so "a parameter with a default is an option, given by name" no
  longer says which arguments are name-only. To a Swift reader,
  `Mapping(generated_position:, source_index:)` is a function reference.

## Cost, re-estimated

| Piece | rig.md | With the above |
|---|---|---|
| punning | 30 | 30 |
| spread, struct update | 350 | 500-650 (name leaves, type-directed sigils, spread-last, round-2 messages) |
| `f.Options` | 250 | 250-300 (cycles, identity) |
| groups | 400 | 600-800 (IR signature rewrite, or ownership/storage/emit declaration side) |
| **v1** | **~1.0k** | **~1.4-1.8k** |

The call path (`ArgSlot`, loans, `callHoistsArgs`, `emitArgsFrom`) is
indeed untouched by a rewrite. The declaration side of ownership, storage
and emit is not, unless the signature is rewritten in the IR.

## Verdict

**Sound with these fixes.** The rewrite idea is right: the existing checker
re-checks what is emitted, so most mistakes become refusals, not wrong
programs. Two findings are not refusals:

- #5: a silent reorder through function values;
- #2: masks misaligned if groups are flattened only in sema.

Both must be fixed in the design. #3 and #4 are spec errors that would refuse
ordinary code. The cost is about 1.5x the claim. Cut for v1: read views in
groups, and functions with options as values.
