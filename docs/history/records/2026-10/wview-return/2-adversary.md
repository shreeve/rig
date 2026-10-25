# Adversary: return `!s.value` from `if !@slots[j] as s`

Today a lend through `s` is a loan on the local `s`, and `checkEscape` rejects it. `return s` already passes (`Map.edit`). Probed with bin/rig 0.2.9.

**H1. Code that runs after the return (a real bug today).**
```rig
if !@slots[j] as s
  defer s = Slot(items: List())   # or a deferred |!s| closure, or t = reset(!s)&
  return !s.items[0]
```
`return s` plus `defer s = Slot(key: 99, ...)` is accepted and prints `99 from defer`. A deferred `|!s|` closure and a task on `!s` also pass. A whole view only aliases. An interior view dangles once the buffer is freed. **Restriction:** defers, closures they call, waited tasks and drop bodies are uses after the return, and may not touch `s`. Fix this for `return s` too.

**H2. Swapping the loan outside a return.** If `r = !s.value` carried only `s`'s loans, then `s = Slot(...)` would free what `r` points to. Today that is rejected. **Restriction:** keep the loan on `s`. Swap it only at the escape check.

**H3. `from @o`.** `if !@p as s; return !s.value` must be rejected. **Restriction:** use the header's own loans, path for path, never "a loan on `@`".

**H4. Subjects that are not lent places.** Held hidden vars (`if !(@).owned() as s`), temporaries and `arm_of`/`erased_of` stay local and are rejected. Chains (`x` → `y = !x.c` → `!y.d`) resolve one header name at a time. A plain `w = !@o` stays rejected.

**H5. Several results.** `return !s.value, ?s`: check sentence 5 between the results before the swap.

**H6. Guards.** In `return !s.value if c`, the loan starts only on the returning edge.

**Probed safe:**
- Writing or moving `@o` or `@slots` before the return (`s` is live).
- A binding from one iteration returned in a later one.
- A fall-through that uses `@` (Polonius #3).
- Two `!@slots[i]` views at once.
- A resize after the `if`.
- A caller that keeps the result and calls `!@` again (rejected, narrowed by `from @o`).
- `V = Int`.
- `match !` payloads can't be returned at all yet. That is a separate limit, under the same rule.

**Minimal safe rule:** at a `return` or a last value, a view lent through a name that a header bound as a write view of a lent place carries that name's loans on their exact paths, not a loan on the name. This holds only if nothing that runs afterward uses the name: a defer, a closure it calls, a waited task, or a drop body. Everywhere else the loan on the name stays.

Probes: `/private/tmp/claude-501/-Users-shreeve-Data-Code-rig/1762ad8a-9823-467a-b54f-a392863cb42c/scratchpad/p/`
