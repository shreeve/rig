# `from @field`: adversary (expert 3)

**Context.** Case 2 is mostly CORE s.7 already (the `Cursor` example). Map iterators fail only because `sema.viewReach` walks a generic type's arguments as owned. SPEC's Scanner is case 2 (`text: ?String`). With `text: String`, its second `(!@).digits()` is still rejected (H1).

**H1. Other `!@` calls.** `r = (!s).digits(); !s.reset(); print(r)`: `reset` may reassign `@text`. *Restriction:* `!s`, `(!s).m()`, `<s`, `s = x` touch all of `s`. Do not infer write sets. Case 1 only frees direct paths (`s.pos += 1`, `(!s.value).m()`).

**H2. Body escapes its clause.** `from @text` returning `?@value[..]` or `pick(?@text, ?@value)`. Or `Two[I: Iter]`'s `from @a` returning `(!@b).next()`: the caller's `(!t.b).m()` then frees a `Buf`-like item. Generic bodies don't track type-parameter views, so this would pass. *Restriction:* check bodies with default origins, bound calls included.

**H3. Case 1 field holding views.** `words: List[?String]`, `first(?@) -> ?String from @words`. If `r` carries only `b.words`, then `!w.add("!")` after `b`'s last use frees `r`'s bytes. *Restriction:* the result also carries all loans self holds.

**H4. Owner-like field as case 2.** `h: *Buf` with no loan on `s`: `s.h = *Buf(...)` drops the last count under `r`. The same holds for `^T`, a type variable `x: T` (at `T = ?Map`), and `!Map` fields (§5 forbids those). *Restriction:* case 2 only for declared read-view fields (`?T`, `[]T`, `?String`, an optional of one). Paths stop where §5's stop.

**H5. Caller can't split self's loans by field.** `retarget(!@, m: ?Map) keeps m` sets `@map = m`. *Restriction:* a case 2 result carries all of self's loans and none on self. Sound under reassignment, since loans attach at the call.

**H6. APIs.** `from @buf` (case 1) still lends from self. `Wrap[I]`'s `inner: I` is case 1. *Restriction:* `[I: Iter]` accepts an instance iff `next` is case 2 only or reaches nothing. Function values drop `from` (sound).

**Closures, defer, tasks.** Nothing new: `|!s.pos|` is a path lend, and `|!s|` touches all of `s`.

## Minimal safe rule set
1. `from @p`: `p` is a §5 path of self.
2. A read-view `p` gives all of self's loans and none on self. Any other `p` gives a loan on `self.p` plus self's loans.
3. Bodies are checked with default origins, bound calls included (needs generic view tracking).
4. Caller touching unchanged; no write-set inference.
5. Never case 2: write-view, handle, box, and type-variable fields.
6. Iter instances are accepted iff case 2.
