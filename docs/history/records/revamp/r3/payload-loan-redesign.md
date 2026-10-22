# payload-loan, redesigned

## Why

The fact is **can a write go through this binding**. Each review found a binding where two deciders disagreed about it:

- review 1 found C2: a `match !e` payload binding lent with no loan;
- review 2 found C1: a read-match binding typed as a write view while ownership lent it as a read;
- review 3 found the C1 variant: a read match of a part of a value made in the header (`match mk(!p).e`), which typecheck exempts (`.held`) while `lendTarget` still lends the binding as a read.

There are two deciders: typecheck chooses the binding's TYPE (`readsHeldWriteViews`, `matchesInPlace`, `.held`), and ownership chooses its LOAN (`lendTarget`, `payload_view`, `payload_writes`, `matchMode`). Every hole sits where they disagree. Under AGENTS.md this is the second soundness round, so the feature stops and gets a redesign.

## The redesign: one recorded fact

1. **One decider, `bindingAccess(binding)`,** recorded once per view binding: `.read` or `.write`. It is decided by a positive list over every binding kind:
   - `match` payload, catch-all and named fields;
   - `if`/`while … as`;
   - `for x in`;
   - closure captures;
   - `!T`/`?T` parameters;
   - held views.

   It looks at how the subject is reached (written lend, read, owned place, made value or held part) and what the payload holds.
2. **Typecheck derives the binding's type from it.** `.read` gives the read view of what the binding reaches, so `!T` becomes `?T` and `![]T` becomes `[]T`. `.write` gives the write view. No other code in typecheck decides a binding's mode.
3. **Ownership derives the loan from it.** `lendTarget` reads `bindingAccess`: `.write` lends a loan on the var plus the loans it holds; `.read` lends only the loans it holds. `payload_view` and `payload_writes` go if the fact subsumes them.
4. **Emit reads the same fact** (through Facts): the copy-out `.*` for a read binding of a by-value view, and the pointer for a write binding.
5. **A unit test checks the structure.** Neither ownership nor typecheck may derive a binding's mode except through `bindingAccess`, in the same style as the existing structural tests (no `recordRead` outside `readOf`, and so on).
6. **The `.held` exception goes.** A read match never writes through its binding, whatever the subject. To write, use `match !…`; for a held part, name it first: `h = mk(!p)`, then `match !h.e`.

## Kept from r1 (tag `payload-loan-r1`, 14d85287)

All tests, the `lendw.` matrix family, the corpus probes, the docs, the emit copy-out and the `test/run` harness fix.

## New tests

- every probe from review 2 (`review-payload-loan-2-probes/`);
- the held-subject family;
- the nested-read-match case, which must either run or be rejected with a message that names `match !o`;
- hints that follow the access: "write `match !e`", never "lend it to write: `!w`" on a read binding;
- `lendw.` cells for held subjects.
