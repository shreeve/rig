# Expert 2: compiler implementer (main 1712e783d)

**Precedent:** not `?fun` (no value holds one; `*fun` holds no loans), but `^T` of a view-holding type and closures' `env_drop_reads`.

## Sentence by sentence

1. **Erasure keeps loans.** Buildable.
   - Decided by the `lendsAs` row `.erase`, or by a move for a box; recorded in `SemContext.erasures`.
   - Risk: `carry`, `mayHoldView` and `holdsViewOnly` narrow loans by `TypeInfo`. An object has no fields, so they would drop its loans.
   - Fix: intern `api_object` (without `Owned`) with conservative TypeInfo: it may hold any view. Not `holds_type_var`: its `.depends` waits for an instance.
2. **A call passes only what the API shows.** Mostly built.
   - Already done: the conformance check (typecheck ~20017) allows `keeps`/`from` narrower than the API, never wider. #605 forbids `from @field` in an API.
   - To add: `callParamsOf` reads the API's field for `Dispatch.dynamic`.
   - Risk: the `== .static` tests (ownership 4826, emit 8024/8091/8524) silently skip `.dynamic`. Use one `Dispatch.viaApi()`.
3. **A box's loans last to its drop.** Buildable: `dropRunsBody(^{A}) = .yes`, and `holderLive` does the rest. The plan's `.maybe` is not an `Answer`.
4. **`!{A}`: only method calls.** Listing write sites is not one classifier. Instead: `{A}` is unsized, so no expression, binding or type argument has that type, whether written **or inferred**. Check it in `inferTypeArgs`/`unify`, or a generic `swap(!a, !b)` writes a Circle into a Square.
5. **Frame copy.** Not checkable as written.
   - "Frame" is too coarse: a loop overwrites the slot each pass, and objects stored across passes alias it.
   - `rig.ReadView`, not sema, decides whether a generic `?T` is a copy, so every such `?T` must count as one.
   - Build: a hidden local (`StorageBy.copy`, a new `StorageLife.block`) or the named var. Ownership roots the loan **at that var, never through `walkThroughView`**, which would reopen Stage 3's dangling `?@`. "A view may not outlive its root" does the rest.

**Oracle:** an `objectInfo` beside `callableInfo`, from the type. Ownership and emit read facts only.

## CORE edits
- S3: "…its loans last until its drop; `Owned` admits only values holding none." ("Unless `Owned`" is vacuous.) Add: the loans of `?{A}` and `!{A}` end at their last use.
- S4: "An object's value has no type a program names, so only its methods reach it."
- S5: "Erasing a view held as a copy views that copy, a local of the erasing block, as any view of a local."
- §4: the box form is a move, not a lend.
