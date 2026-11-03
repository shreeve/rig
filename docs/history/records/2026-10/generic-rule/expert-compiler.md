# Expert: compiler and oracle (2026-10-27)

Probes: `closure-view-fix` (a2bffca06), `RIG_SANITIZE=1`.

## New facts
- **Two more routes give use of freed memory:**
  - (a) A generic Rig method: `Pair[V].upd(!@, f: ?sub(?String, !V))` calls `f(?@k, !@v)` at `V = (?String)?`, with `|k, v| v = k`, then `@k` is rewritten. The non-generic copy is rejected ("a value never holds a view of itself").
  - (b) Through a result: `ensure_with(String(..), |k| k)` on `Map[String, (?String)?]`, then `take`.
- **R2 contradicts the Core as built.** CORE.md:1958 and SPEC.md:3100 say a closure "keeps what its type could hold". A closure is checked by `typeOrigins` (ownership.zig:6017, 6227), which is `sema.defaultOrigins` (sema.zig:11351). It has no `declKeeps` narrowing (sema.zig:11571-11606).

## 1. Owners and size
- **R1.** The classifier is `defaultOrigins` of the callable type at the instance. If `(result | stores) & lent ≠ 0`, the instance is refused.
  - It refuses `(?String)?` and `List[?String]`, not `String`, `Int` or `?List[Int]` (probed).
  - Marked in two places: the table's `update`/`retain` (resolve.zig:5205-5225), and the self-rooted stores that genericStoreIn drops today (ownership.zig:6290, 7740-7765).
  - Propagated as `GenericMethodCall` is. Checked beside the `owned_recv` refusal (typecheck.zig:20466). Emit is untouched.
  - About 80-110 lines, half there (`api_call` at ownership.zig:7757, `owned_recv`).
  - It covers (a), (b), both known cases and `put_view`.
- **R2.** About 15 lines: narrow `typeOrigins` by lent, and check a function value's `keeps` against its type.
  - It misses (b): returning a parameter's view stays allowed.
  - It also relaxes the caller side, so `apply` is accepted. That is a CORE change.

## 2. New rejections
- **R1:** none in std or Trig. Trig never calls `update`, `retain`, `ensure_with` or `ensure_by`.
- **R2:** none in Trig. Of Trig's 65 callable types with write parameters, only diagnosticwriter.rig:319 has a view parameter, and it writes a `!String`, which holds no view.
- **R2 breaks about 12 Rig cases** that encode "a callable may store":
  - ownership-misc-1: 6101, 6119, 6152, 6169, 8541, 8629;
  - ownership-keeps: 108, 257, 304;
  - probes-10: 195; probes-16: 2160, 2279;
  - SPEC.md:3100.

## 3. Oracle
- `keeps_named` is set only for named declarations (lower.zig:534), so C6 (flow.zig:682) never checks a closure.
- It abstains on the known `update` case, and rejects `Pair.upd` with C9, a DIFF from the compiler.
- R1 needs the same instance rule in its generic-body check (lower.zig:372-435): about 30 lines.

## 4. `!?List[Int]` `.len`
- It is not specific to closures: a written `show(v: !?List[Int])` passed to the generic `Box[?List[Int]]` fails the same way.
- Cause: emit gives `rig.lenOf(rig.rt(__rig_in_v))` for a `**const List`, stripping only one pointer.
- Neither rule fixes it, since `?List[Int]` is not refused.
- #737's class does: widen `writesTextView` and resolve.zig:3885 to any `!?T`, about 6 lines. A `!?T` arises only by substitution.

**Recommendation:** R1, plus widening `!?T`.
