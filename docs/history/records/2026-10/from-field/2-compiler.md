# `from @field`: compiler implementer (panel 2)

Read on origin/main 06b22a585.

## Parse and record
- **Grammar:** `rig.grammar` `onames` accepts `oname "." name → (member 1 3)`, because `@text` lexes as `@ . text`. A path in `keeps` is rejected.
- **The fact:** `sema.declaredOrigins` (~9330) resolves the path and records `Origins.self_paths: []SelfPath{fields, via_view}`, once. `via_view` means the last field is declared as a read view (`?T`, `[]T`, `?String`). A `!T` field or a type-variable field counts as owned, which is conservative. Bit 0 stays set, so the mask readers don't change.
- **Errors:** no such field; a field that cannot hold the result's view; a path past a view ("write `from @map`"); an API naming a field ("an API names no fields: write `from @`").

## Call site (`ownership.walkCall`, ~4583)
- **Owned path:** the result carries `lendOn(recv_root, child(recv_path, fields))` instead of the whole receiver.
- **`via_view`:** the result carries what the receiver holds (through `carry`), plus what this call stores, and no loan on the receiver itself.

## Body (`recordResult` / `checkOrigins`, ~5650)
- Gated on `self_paths`, `lendOn` tags the receiver's ext loan with the field path. `walkThroughView` tags it with the path of the first view step and a new `Loan.via` flag (added to `sameAs`).
- `checkOrigins` reports any other path, and reports a direct lend of a `via_view` field: "returns a view of `@map` itself; `from @map` gives what it views".

## Iter rule
`sema.assocViewsBase` (~6830) finds the base's `next`. If every `self_path` is `via_view`, it accepts. Otherwise it applies today's `viewReach == .owned`.

## Stage 3
The mask test at typecheck ~19960 already treats `from @field` (bit 0) as narrower than or equal to the API's `from @`. A call through the API uses the API's whole-self origins, which is sound.

## Oracle
- `declaredFrom` reads paths.
- `resultCarry` (~3527): an owned path lends the receiver place plus the path. `via_view` carries the receiver var's carried vars.

## std and docs
Add `from @map` to `Items`, `Keys` and `Values`, and `from @set` to `Members`. Flip `fail "iter a map's iterator"` to a test. Un-pend SPEC's Scanner (`text: ?String`, the via case).

## Tests
- **Pass:** write `b.n` while `b.head()` lives; two live `!k.next()` items; `iter.count(!k)`; `!b.slot() += 1` (`-> !Int from @a`) while writing `b.c`; generic `Wrap[T]`.
- **Fail:** write `b.text` while the result lives; `!m.put` while a key lives; the four declaration errors; both body errors; an own owned-field `from @buf` iterator through `[I: Iter]`.

## Size and risks
About 300 source lines plus 150 test lines.

1. Keep the hot `lendOn` path gated.
2. via_view relies on a read-view field never letting `!@` change what it views. Reassigning `@map` is covered by "plus what this call stores".
3. When the receiver is a view variable, only that variable's own loan is narrowed, which is conservative.
