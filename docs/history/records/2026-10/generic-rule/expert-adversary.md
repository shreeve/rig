# Expert: adversary of R1

Probes: `adversary-probes/`, `run.sh` (sanitizer on).

## Holes R1 must cover (accepted, use of freed memory)
- **a03:** two write views and no read view, `f(!@a, !@b)`. "Beside a view" must count a write view.
- **a04:** no callable. A `K` method's result viewing self, held as a `V`; today only `keeps` is refused. Self counts as a view; the method's `from` decides.
- The same hole through an API object (a05), `Wrap[List[?String]]` (a06), an enum payload (a07), `((?String)?)?` (a08), a `*sub` field (a13), and a by-value parameter (a19, Trig's `group_by` shape).
- Caught: a01, a02, a09 (message names the wrong side), a10b, a14, a11, a16. `$plain(V)` narrowing (a12) is a sound escape but excludes an owned `V` such as `String`.

## "Can hold a view"
The instance's argument lacks `Owned` (`lacks(.Owned)`, which is `mayHoldView`). That is a view, write view, slice, or `?String`, reached through:
- optionals, arrays, fallibles, results;
- fields, payloads, every generic argument;
- `*` and `~` handles, but not a frozen `*{A + Syncs}`;
- an API object without `Owned`, and `Task`/`Tasks`.

Not into a Cell, Signal, actor, or channel value, or a function type. A type parameter is answered by its `Owned` bound, or per instance through forwarding (`liveAt`, `$plain`). It applies to the write target's or held result's type variables, never the view argument's.

Recorded as `requireNoView`, which Cells use; checked by `checkViews`. The built-in table's `update` and `retain`, and `insert_new`, declare it by hand.

## Cost of R1 as worded
- **std:** `Map.update`, `retain`, `ensure_with`, and `sort_by_key` (its local keys count: STD.md:969 `|p| p.name`, a18).
- **tests:** probes-16 "rev240-m03 value kinds" (`Map[?String, ?String].retain(|k| ...)`) is refused. types-write "…from retain's type" changes its `errors:` count. Known cases pass.
- **Trig:** 0 refusals. It calls none of these, and its callable generics have no instance with a type argument that holds a view.

## Refinements
1. **P1 (recommended).** Require it only where the view reaches memory the body owns: locals, by-value parameters, or self's storage (ViewReach `owned`). Lent parameters are already tracked (a21 demands `keeps s`). Removes the `sort_by_key` refusal.
2. **P2 (marginal).** Use CORE 7's `defaultOrigins` at the instance's callable type.
3. **P3 (defer).** Discharge the requirement when the callable is a literal closure or a declared function whose checked body stores and returns no parameter loan. This accepts p12, a17, a20, and probes-16; a check per call.
