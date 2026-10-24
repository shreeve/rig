# Adversary: shared and crossing API objects

**A1, a weak handle on a frozen value (high).** Open question 10 lets `~s` weaken a `*{Shape}` hiding a frozen allocation:

`t = keep(+f)&; s: *{Shape} = <f; w = ~s; <s; *w` races `t`'s last drop.

This breaks SPEC's "a frozen value has no weak handle". The runtime has none either: `Weak(T)` points at `Shared(T)` and counts atomically only for `synchronized(T)`. Its `upgrade` and `dropWeak` are plain, against an atomic last drop: use after free, double destroy. *Fix:* a frozen handle erases only to `*{A + Syncs}`. No bound is added or dropped between the two forms, so a `*{A}`'s counts are never atomic.

**A2, `Syncs` in a generic.** In `sh[T: Shape + Syncs](h: *T) -> *{Shape + Syncs}`, `T` syncs but `*T` counts plainly. *Fix:* only `*Frozen[T]` erases there.

**A3, made local, not rejected.** SPEC §18 makes a task given a value that never crosses *local*, and a `^{Shape}` is such a value. Question 13's hole reopens: `val(?h)&` of a `*Holder` holding one, `par`/`select` captures, `T = ^{Shape}`, `?s` of a `*{Shape}`. *Fix:* add "an API object without the bound" to SPEC's list of what a local task never takes.

**A4, a weak handle with no loan.** If `~{A}` carries no loan, `*w` gives a count that has escaped the loans its value holds. *Fix:* `~{A}` carries `*{A}`'s loans.

**A5, variance (H3 again).** `!sq` as `!*{Shape}` writes a Circle into a `*Square`; `?*Square` as `?*{Shape}` reads 8 bytes as 16. *Fix:* erasure only moves or counts the handle.

**A6, `Sends` is not `Owned`.** Channels, actor state, owned closures and errors keep H1: no `Owned`, any view.

**A7, phase 4.** `*fun` is never a `*{A}`. Its row stays "never".

**Probed sound:** counts in a drop; a task's drop reading a loan; `?{A + Syncs}` under a writer; parts gained later; `from @field`.

## Minimal rules
1. `*{A}` takes only a plainly counted `*T`; `*{A + Syncs}` only a `*Frozen[T]`, which has no `~`. Neither converts to the other.
2. Atomicity, frozen-ness, hidden tasks and `Owned` are checked per instance.
3. One crossing walk rejects an object without its bound anywhere a task can reach it, and never makes the task local.
4. `~{A}` carries `*{A}`'s loans.
5. Erasure only moves or counts a handle.
6. Without `Owned`, an object holds any view.
