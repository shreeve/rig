# Named options, groups and spreads (2026-11-22)

The question began as the owner's idea, from the Crystal review's
Swift lens (docs/IDEAS.md): **a parameter that has a default, other than
the first, can only be given by name.** A panel of three tested it against
a temporary compiler patch that counted every call it would change. The
owner then asked for Zig's options value on top of it: options that can be
built once, stored, passed whole, forwarded and partly overridden. A
committee of three designed that, two red teams attacked the result, and an
outside review the owner shared added four points. The design states the
result ([docs/design/options.md](../../../../design/options.md)); this
record says how it was decided.

## How it was decided

| Step | Who | Report |
|---|---|---|
| The keyword rule, measured | a temporary patch that logs each call the rule would change, run over Rig's suite, std, docs, tools, bench, Trig and loco | [kwonly/calls.tsv](kwonly/calls.tsv), [kwonly/summary-raw.txt](kwonly/summary-raw.txt), [kwonly/std-decls.txt](kwonly/std-decls.txt), [kwonly/patch.diff](kwonly/patch.diff) |
| Panel of three on the rule | a language designer; an evangelist; a practitioner of Rust, Zig, Swift and Go | [kwonly/designer.md](kwonly/designer.md), [kwonly/evangelist.md](kwonly/evangelist.md), [kwonly/practitioner.md](kwonly/practitioner.md), from [kwonly/PANEL.md](kwonly/PANEL.md) |
| Committee of three on options as a value | an innovator; a Zig and systems view; Rig's compiler view, which wrote the recommendation | [opts/innovator.md](opts/innovator.md), [opts/zig.md](opts/zig.md), [opts/rig.md](opts/rig.md), from [opts/BRIEF.md](opts/BRIEF.md) |
| Two red teams on the recommendation | design coherence, evolution, teaching and precedent; the compiler's code | [opts/redteam-design.md](opts/redteam-design.md), [opts/redteam-code.md](opts/redteam-code.md), from [opts/REDTEAM.md](opts/REDTEAM.md) |
| The consensus put to the owner | | [opts/CONSENSUS.md](opts/CONSENSUS.md) |

The probe programs the reports cite are kept beside them: `kwonly/designer/`,
`kwonly/evangelist/` and `kwonly/practitioner/` (the panel), `opts/inn/`
(innovator.md), `opts/zig/` (zig.md: Zig 0.17.0 sources and their
ReleaseFast assembly for aarch64-macos and x86_64-linux), `opts/rig/`
(rig.md, p1-p12), `opts/red/` (redteam-design.md, r1-r19) and `opts/rc/`
(redteam-code.md, t1-t21). They ran against main e38454865 (the panel) and
75a6c7b5e (the rest). Left out as too large: the patch's 4.7 MB log, the
innovator's 3.6 MB count of Trig's `x: x` lines, and the code red team's two
generated 64 KB modules for timing the extra check.

What they found:

- **The measured cost:** 326 call sites (534 arguments) change: Rig's tests
  223, Trig 52, loco 25, std 10, docs 9, tools 6, bench 1. All lie in a
  trailing run of defaulted parameters, so the named form can be written
  mechanically; 174 of them are `Time.new` and `DateTime.new`. None is in
  a function value or a generic body, and emitted Zig is unchanged.
- **All three panelists**, apart, dropped the first-parameter exemption:
  it keeps open `dt.add(1)` (one second), `t.with(3)`, `dur.round(5)` and
  an all-options function's `window(24)`, so most of std's positional
  checks would have stayed. All three put the clock of `DateTime.new` by
  name and rejected dropping every default (seven bare integers); all three
  asked for no default on `_`, no required parameter after an option unless
  it takes a closure, and a trailing closure that fills its callback.
- **The committee** agreed on `..` for groups and spreads, nominal spreads,
  object update and the shorthand. The Zig review measured that a 40-byte
  struct parameter costs a frame and a copy when Zig does not inline the
  call, where separate arguments are a bare tail jump. Rig's review found
  that a spread fits Rig as a rewrite into keyword arguments, checked
  again, as iterator chains are, rather than a new kind of argument slot.
- **Both red teams** found the design sound with fixes, nothing fatal. The
  serious findings: a function value calls options by position, so a
  group's field order would become a silent positional contract; adding a
  `Duration` field to a shared group would take the unit keywords from
  every caller; a forwarding wrapper could discard what its caller gave;
  `f.Options` was defined three ways; and, in the code, a group flattened
  only in sema misaligns the ownership checker's parameter bits, a spread's
  nodes need leaves with arbitrary names, and the cost is about 1.4k to
  1.8k compiler lines, not 1.0k.

**The outside review** the owner shared added four points, part of the
decision:

1. Options values are complete: making one fills every default.
2. The language promises no run-time lookup or machinery; how a group is
   passed is the compiler's measured choice, not a language rule.
3. Evaluation order with a spread needs targeted tests, such as
   `connect(host, 5432, ..o, retry: change_timeout(!o))`.
4. Function-type compatibility is decided in writing now, though function
   values with options are refused in v1; adding options is
   source-compatible on recompile, not a stable binary interface.

## Where the reports disagreed, and what settled it

| Point | The reports | Settled |
|---|---|---|
| Spread before or after the names it yields to | innovator, zig and rig.md: the spread first, a name before it "given twice"; both red teams: Rust users write it last, and an update of owners needs it last | named fields win in any order (the consensus) |
| `f.Options` | three definitions (only inline; inline only; every name-only parameter) | deferred (the consensus) |
| What a group holds | rig.md and zig: plain values and read views; the innovator: owners too; the code red team: plain values only, until the parameter bits are fixed | plain data only in v1, lifted in the next step (the owner) |
| Function values | rig.md: their flat type, by position; zig: one ABI, no thunk; the red teams: refuse | refused in v1; the compatibility rule written now |
| A group's lowering | the innovator: one Zig struct; zig: flat | the compiler's choice, separate arguments first (the outside review, zig's measurement) |
| Unit keywords and groups | rig.md: they fill a group's one `Duration`, and override a spread's | never (the design red team) |
| Spreads into checked calls | zig: none; rig.md: the rewrite refuses exactly the unsafe ones | none into `round` and `floor`, which declare no group |
| `DateTime.add`'s `d` | the practitioner: rename it (`by:`?) | `duration` |

## The owner's decisions (2026-11-22)

1. **The rule:** required values first by position; a parameter with a
   default is an option, given by name; a trailing closure fills its
   callback parameter; no first-parameter exemption.
2. **Groups, spreads, object update and the shorthand**, as in the
   consensus, with the outside review's four points.
3. **The v1 limits:** plain data only in groups and object update; no
   function with options as a value; no unit keyword fills a group's field;
   a wrapper does not override its own group's fields; no spread into
   `round` or `floor`. Deferred: `f.Options`, groups in APIs, function
   values that keep their options, generic groups, groups by pointer.
4. **Owners and read views in groups and object update** come in the next
   step after v1, before any other deferred item, with the ownership,
   storage and emit work the code red team described.
5. **Datetime:** `Time.new(hour, minute, second, ns: 0)`, the clock of
   `DateTime.new` by name, `DateTime.add`'s duration named `duration`, and
   `Period`, `DateFields` and `ClockFields` as groups; `round` and `floor`
   keep their units inline.
6. **The order of work:** after error traces and the constant-argument
   rule, the keyword rule, then groups and spreads, then owners in groups;
   the datetime change that applies "total or visible" can follow the
   keyword rule.

## Revised before step 2 (2026-11-22)

A second outside review of the design, and the coordinator, recommended four
clarifications, and the owner agreed:

- **A wrapper may override a field of a group it received:**
  `fetch(url, retries: 1, ..net)!`. Explicit named arguments override a
  spread's fields whether the spread's value is a local, a field, or a
  parameter of the enclosing function. Banning it on a received group gave no
  real guarantee (a wrapper could copy the group into a local and override
  that), and it blocked the main use of forwarding. The red team's concern (a
  caller's `insecure: true` ignored by `connect_safe`) is an API design matter:
  such a wrapper documents its policy or takes a group without the field. The
  v1 limit is removed.
- **The `round`/`floor` limit is narrowed** to calls whose contract requires
  naming exactly one unit; ordinary type and constant checks apply after a
  spread expands.
- **Stored options need a declared group**, stated with an example, since
  `f.Options` is deferred.
- **A group is normalized into ordinary parameters**; how they reach Zig is
  the lowering's choice (separate arguments today, by measurement).
