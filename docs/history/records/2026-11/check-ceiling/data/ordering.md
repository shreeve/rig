All three rules need one piece of work the pass lacks, called **S1** here:

- facts whose subject is an `Int` field of self (`@pos`), with `?String` fields as length places;
- kills by field rather than by root binding (today `Kills.movesLen` ends every fact on a path
  from `self` at any write of `self`, so `@pos += 1` or `!@locs.push(x)` ends `len(@recs)`);
- a write summary per method (which fields of self it writes, and whether it keeps every List's
  length), so that a call `!@f()` ends only what `f` writes.

The shares below are of live check branches, webpack --noCheck. Cycles are those shares times 5.0%.

**1. (a) Narrowing to 32 bits: 8.5% (about 0.42% of cycles), in two steps.**
- *Step 1, no flow facts:* a declared bound on a List or String (its grow path tests the bound,
  so a push makes no test of its own). A conversion becomes a proof use, emitted unchecked when
  proven. A length read of a bounded List is `<= 2^32 - 1`, which proves `U32(xs.len)` wherever
  it is written: 3.5% live (`new_node`'s `data: U32(@words.len)`, `add_text`'s `start`,
  `add_list`'s `start`, the binder's `new_table`, `extra_of`), and `@name_ids.len * 4`. This is
  small compiler work, but it needs the owner's decision on bounded Lists.
- *Step 2, after S1:* `U32(xs.len - 1)` after `!xs.push`, which needs `nonempty(xs)` to survive the
  next push of another field: 4.9% live (`new_node`, `add_text`, `add_list`, `new_symbol`,
  `new_flow_node`, `new_flow_list`).
- *Misses:* the parameter positions (category a+, 6.5% live: `finish_node`'s
  `I32(pos)`/`I32(end)` alone is 4.0% of all branches, the biggest single conversion site), and
  `U32(text.len)` of a parameter slice. Proving those needs facts that cross calls and a source text
  bounded below 2^31. A Trig-side alternative is to carry positions as `I32` from the scanner.

**2. (b) Runs of adjacent indexes: built for one statement; what is left is 9.0% (about 0.45%).**
- What is built already covers the generated accessors' record reads (`binary_expression` and
  the rest). Those checks now sit only on cold slow paths: 7.8% of all branches, about nothing at
  run time.
- What is left is runs read *through a helper*: `set_parent_of_children`'s `!@parent_child(d + k,
  p)` (338 panic branches; `words[i]` in the callee) and the binder's `!@bind_word(d + k)`, whose
  `d + k` adds are also checked.
- *Needs:* (i) a callee summary "parameter `i` indexes `@words` unguarded", lifted to the caller as
  a range use under the existing flag (`okBelow(d, kmax + 1, @words.len)`), with emit passing the
  proof into an `inline` helper (a comptime flag) or calling a checked-free clone; and (ii) S1's
  write summary, since `parent_child` stores `@recs[w].parent` and `bind_word` binds a whole
  subtree, and today either call ends the flag's fact.
- In the binder `d` is a parameter of `bind_children_of`, so the flag must be made there. It
  holds only if binding cannot change `@file.ast.words.len`: a read view of the arena, or a write
  summary that shows it.
- *Misses:* `recs[w]` for the id `w` read from the word. That is category d, and it goes with each
  run: 1.5% of all branches.

**3. (c) Facts about self's fields: 11.8% (about 0.59%), and the most work.**
- Within a method after a test, it removes almost nothing in the hot code. In `char()` the guard
  `@pos < @body.len` gives only the upper test, and the held compare already makes both tests in
  one instruction. In `scan_operator` the bound sits inside `char_at`.
- Its payoff comes from facts held *between* methods:
  - `0 <= @pos`, an inferred non-negative field (every store in the module keeps it): this
    proves `char()` (c2n, 2.7%);
  - the relational invariant `0 <= @token_start <= @pos <= @body.len` (and `@value_start <=
    @value_end <= len`) across `!@scan_ascii_identifier()` and the other calls: the slices and
    `@pos += k` (c2r, 5.0%);
  - `nonempty(@name_slots)` for the probe loops (hash, 2.4%);
  - `char_at` (c2p, 1.7%) needs its callers' literal offsets as well.
- *Needs:* S1, plus either a declared object invariant (a language decision for the owner),
  checked at each store, or inference over every store to the field in the module. The fields are
  private, so all their stores are in the module.
- *Misses:* std.utf8's and std.text's parameter indexes (std, 4.3%), and `skip_ascii_trivia`'s
  `text[p]` with `p` from `class_end`, which needs a result fact `0 <= class_end(s, i, …) <=
  s.len` (a small extension of `Summaries`, 1.0% of all branches).

**(d) for scale: 30.7% live, and 39.1% with the record invariant (d-rec)**, about 1.5 to 2.0% of
cycles: more than (a), (b) and (c) together (29.3%). `Ast.kind` alone (`@recs[n.id].kind`) is
5.4% of all branches. Trig's checker already indexes by bounded handle types
(`rig.SlotOf(2^27)`), so (d) has a ready starting point.

**Not reached by any of the four:** Zig's std and Rig's runtime (10.0%), the parameter positions
(a+, 6.5%), std's parameter indexes (4.3%), decoding (1.3%), counters (0.4%), and the
enum-indexed tables (e, 0.8%). The last is cheap: a table of 352 entries indexed by `Int(kind)`
of an enum with 352 variants needs no test.
