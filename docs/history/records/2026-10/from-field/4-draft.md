# `from @field`: the combined draft (Rig (OG), from panel reports 1–3)

## The CORE paragraph (sentence 7, after "…or, when the result says `from a`, of `a` alone.")

> A method's `from` may also name a path of self, as §5 defines one
> (`from @text`, `from @a.b`), whose type could hold what the result
> views. The result then carries the loans self holds and a loan on
> that path alone, not on all of self, so a use of self's other paths
> may go on while it lives; a use of all of self (`!s`, `(!s).m()`,
> `<s`, `s = x`) still touches the path. When the path is a field
> declared as a read view (`?T`, `[]T`, `?String`, or an optional of
> one), the result carries that view's loans and none on self, so self
> may be lent again, even to write, while the result lives. The body is
> checked against the path it names, a view that comes back from a call
> on a type parameter included. *(built)*

## The rules, each with its reason

1. `p` is a §5 path of self: fields, through boxes; it stops where §5 stops (an element, a handle, an optional's value). A path through a read view is rejected with "write `from @map`". (Core 1; compiler)
2. **Owned path:** the result carries a loan on `self.p` *plus every loan self holds*, otherwise `words: List[?String]` with `first(?@) -> ?String from @words` lets the viewed strings' owner be written once `b`'s last use passes (adversary H3).
3. **Read-view field:** the result carries the field's loans and *all of self's loans*, and none on self. Sound under `@map = ?other` because loans attach at the call (adversary H5).
4. **Never read-view treatment** for write-view, handle (`*T`), box, or type-variable fields: they get rule 2 (a path loan). A handle field as rule 3 would free the last count under the result (adversary H4).
5. **Callers:** no write-set inference. Any lend of all of self touches the path (adversary H1). The benefit is direct path uses (`s.pos += 1`, `(!s.value).m()`) and, for rule 3, any use of self.
6. **The body:** every returned view must come from the named path. A call on a type parameter's value (`(!@b).next()` through a bound) is treated as viewing its receiver (the API's whole-self origins), so `from @a` returning it is rejected (adversary H2). The compiler tags receiver loans with paths, gated so `lendOn` stays fast (compiler).
7. **Combined:** `from @map, k` carries both. `from @, @text` is rejected (one holds the other).
8. **Through a bound:** `from @field` is within the API's `from @` (narrower), and a call through the API uses the API's whole-self origins. An API names no fields ("an API names no fields: write `from @`").
9. **`[I: Iter]`:** an instance is accepted iff its `next` names only read-view fields (rule 3), or its item reaches nothing; otherwise today's strict rule holds (adversary H6; compiler `sema.assocViewsBase`).
10. **std:** `Items`, `Keys` and `Values` get `from @map`, and `Members` gets `from @set`. `fail "iter a map's iterator"` becomes a `test`. SPEC's pending Scanner (`text: ?String`, a rule 3 case) becomes an ordinary example.

## What it does not change
Run time (checker only); function values (no `from`); `keeps` (parameters only); several results; loan kinds and conflicts.

## Examples for CORE (from panel 1)
`Reader` with `text: String`, `seen: ?List[Int]` and `at: Int`: two live `(!r).next()` items `from @seen`, a `?r.word()` `from @text`, then `r.at = 0`, printing `hi 7 8`. The reject case: `word` says `from @text` but returns `?@name[..2]`, giving "`word` returns a view of `@name`, but its signature says it views only `@text`".

## Build (panel 2): about 300 source lines and 150 test lines
- grammar `onames` path;
- `sema.declaredOrigins` records `self_paths{fields, via_view}`;
- `ownership.walkCall` (~4583) and `recordResult`/`checkOrigins` (~5650);
- `sema.assocViewsBase` (~6830);
- the oracle's `declaredFrom` and `resultCarry`.
