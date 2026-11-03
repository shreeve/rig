# A parameter's optional field moves: the final CORE text for the owner

The panel had two adversaries (drops and flow; captures, tasks and generics) and a reviewer (the text and the oracle). Both adversaries found the change sound: no double drop, no leak, and no accepted program changes meaning. The reviewer agreed and fixed the wording.

## CORE §5, after "…no use touches all of `p` except `p = x`."

> An optional field is taken, leaving `none`, where `p.f = x` could
> assign it; of a parameter, a capture, or a `=!` local, where it could
> not, it moves like any other field. *(built)*

**Why this wording.** What matters is whether the field can be written, not whether the binding can be reassigned. Loop and `as` bindings can't be reassigned, but their fields can be written, so they keep the take. The sentence ties back to the paragraph's own "`p.f = x` makes a local's field usable again".

## What it means
- **Now accepted** (it was rejected before):
  - `count(<p.tags)`, `got = <p.tags` and `if <p.tags as t`, where `p` is a parameter;
  - the same through captures, `=!` locals, tasks, `once` closures and generics.
- **Unchanged:**
  - write views (`p: !Pair`, `|!p|`), loop and `as` bindings, and locals that can be assigned still take and leave `none`, with the same output as before;
  - a type with a `drop` body still can't give up a field;
  - using `p` whole after the move is still rejected.

## Fixes folded in before merge
1. SPEC and CHANGELOG are reworded to match.
2. A generic `T: Copy` optional is rejected like a concrete one.
3. A box keeps its old message.
4. The oracle decides `once` closures and tasks, or the PR records that as a gap.

## Gates
- The Mac full suite is green.
- Loco's light gate is GREEN.
- Trig's light gate is GREEN (merged onto main).
- These re-run after the fixes.

Reports: A.md, B.md, C.md.
