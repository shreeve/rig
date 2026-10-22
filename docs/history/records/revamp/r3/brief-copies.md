# Brief: one "copies" fact (the design owner's item 3)

**The goal.** Remove four type lists that each re-decide "a value that copies" with their own list, which breaks CORE §10 (no exception lists) and AGENTS ("one classifier per fact"):
1. **Copying out of a read view** works for numbers, Bool, String and plain enums, but not for plain structs, arrays or optionals (CORE §4 marks plain structs as planned).
2. **A bare write view of copy data reads its value** (CORE sentence 1, built in round C): the same list.
3. **`fill` and `[n of x]`** require "plain data" (`isPlainData`), a different test from what a plain binding uses (`copyable`). CORE §5 now says they're built for elements that hold no view; read-view elements are planned.
4. **`|+x|` captures** work only for plain data and handles; CORE §7 marks a deep copy of an owner as planned.

**The decided direction.** One fact, "copies", says whether a value is duplicated by a bit copy with no owner involved. It's true for plain structs, arrays and optionals of copies, and for read views. Every place above asks that fact, so plain structs, arrays and optionals copy wherever numbers do.

The "copies" fact is distinct from "clones" (`+x` deep-copies owners, step 5's `cloneable`). Decide `|+x|` of an owner (deep clone) and read-view elements in `fill` by the Core's planned status: build them if the one fact makes them fall out naturally and safely; otherwise leave them planned and say so.

**Proof:**
- tests first;
- equivalence against the previous release binary: ZERO programs go from accepted to rejected, and every newly accepted program is listed;
- the four gates through r3/heavy.sh;
- `oracle doc vocab`, with the oracle taught the same fact by its own model;
- CORE status words updated (§4, §5, §7, sentence 1), with running examples;
- an independent review follows.
