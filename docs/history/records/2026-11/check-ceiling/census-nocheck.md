# Census: which of Trig's unproven checks four proof rules would remove (Mac, c1)

Trig faeb512b, Rig 383a1b2b5 (emitted Zig and binary from `c8-check/A`, built with aa348b342,
whose only difference from 383a1b2b5 is `src/sched.zig`, so the emitted Zig is the same). Analysis
only: nothing was built into Rig.

## Method

1. **Every panic branch, tied to its source.** `tools/sites.py` takes each conditional branch to a
   panic in every profiled function of the checked binary (as `tools/panics.py` finds them) and
   asks `atos -i` for its inline chain, so a check inlined from `Ast.kind` into
   `parse_statement` is tied to `ast.zig:446` inside `Ast.kind`. That gives 10,499 branches in
   323 functions for the noCheck profile.
2. **Weight.** Each branch gets its function's self samples divided by the function's
   instructions, as the ceiling's `weighted.py` does, so the totals per kind match ceiling.md:
   index 59%, conversion 14%, overflow 12%, slice 6% (`tools/agg.py`). `tools/sitetext.py`
   adds the Zig line, and `tools/rigloc.py` the Rig function the line belongs to.
3. **Classify.** `tools/classify.py` splits each (site, kind) among the categories below. It uses the
   helper that holds the site and the operations on its Zig line, and a line with two operations
   of different categories (`@lists[@words[i]]`) is split between them. I read the top 120 sites
   (75% of the weight) by hand. The rest go by the line's pattern.
4. **Live share.** Two categories are branches that do not run: the slow paths of the flags
   `proposeFlag` already makes (`atIf`, `addIf`: taken only when the flag is false), and the
   deliberate panics (`_ = s[i]` in std.text's `class_end`, which panics on purpose outside
   `0..s.len`). Density weighting counts them like any other branch, so I report every
   category's share of all branches and its share of the *live* branches (those two left out). The
   cycle column is the live share times the measured cost of all checks for that run. For webpack
   --noCheck that cost is 5.0% of c1 cycles; across the six runs it is 2.6 to 7.5%.

Caveat: density weighting spreads a function's samples evenly over its instructions. A check in
a hot loop is worth more than this says, and one on a cold path less. Scan shows how big the gap
can be: the ceiling measured 3.4 of the 28 ms the checks cost there (12%), but its branches get 7%
here.

## Categories

| category | what the check is | rule that removes it | what the prover needs at the site |
|---|---|---|---|
| **d** | index by a handle into a grow-only List: `@recs[n.id]`, `@locs[n.id]`, `@lists[l.id]`, `@texts[t.id]`, `@recs[w]` for a node id `w` read from a word, the binder's `flows[f]`, `symbols[s]`, `node_flow[n.id]`, the checker's `store.types[t]` | (d) | a handle type tied to its List (or `Table` + `Slot`, which emit already writes with no test) |
| **d-rec** | index or slice inside a handle's record: `@words[Int(@recs[n.id].data) + off]`, `@list_nodes[r.start .. r.start + len]`, `@text_bytes[r.start ..]`, `@words[d + i]` over `LAYOUT[kind]` | (d) and a record invariant | (d), plus "a node's words, and a list's ids, lie inside `words` and `list_nodes`" |
| **b-built** | flag slow paths: the generated accessors' `words.atIf(d + k, …)` under `okBelow(d, n, @words.len)` | (b) is built (`proposeFlag`, record reads) | nothing: these run only when the flag is false |
| **b+** | runs of adjacent words read *through a helper call*: `!@parent_child(d + k, p)` in `set_parent_of_children`, `!@bind_word(d + k)` → `@file.ast.word(i)` in the binder; and their `d + k` adds | (b) across a call | the callee's unguarded `@words[i]` lifted to the caller as a range use; a write summary of the callee (`parent_child` stores only `@recs[w].parent`, so it keeps every length; today a `!@` call ends every fact about self); and for the binder, `d` is a parameter, so the flag must sit in `bind_children_of` itself |
| **a** | `U32(xs.len)` and `U32(xs.len - 1)` of a List or String field: `new_node`, `add_text`, `add_list`, the binder's `new_symbol`, `new_flow_node`, `new_flow_list`, `new_table`; `@name_ids.len * 4` | (a) | a declared bound on the List, so a length read gives `len <= 2^32 - 1` (this alone proves `U32(xs.len)`, 3.2 of the 7.6 points); for `xs.len - 1`, also `nonempty(xs)` after `!xs.push`, which survives the next statement only with field-level kills (`new_node` pushes `@locs` between, which today ends every fact about `@recs`) |
| **a+** | `I32(pos)`, `I32(end)` of parameters in `finish_node`, `add_list` and `set_loc`; `U32(text.len)` of a parameter slice; `U32(@scanner.token_start)` | none of these | facts about parameters from every caller (`finish_node` is `pub` and called from parser), plus positions bounded by a source text known to be under 2^31 bytes. (a) as stated does not reach these |
| **c2n** | `Int(@body[@pos]) if @pos < @body.len` (`Scanner.char`) | (c) | the guard gives the upper test within the method. The lower test (`0 <= @pos`) needs a fact held between methods: every store to `@pos` in the module is non-negative. One held compare makes both tests today, so proving only the upper one saves nothing |
| **c2r** | `@body[@token_start..@pos]`, `@text[@value_start..@value_end]`, `@pos += k` | (c) between methods | the relation `0 <= @token_start <= @pos <= @body.len` (and the same for `value_start`, `value_end`) held as an object invariant across `!@scan_ascii_identifier()` and the other calls between the stores and the use |
| **c2p** | `@body[@pos + offset]` and the add in `Scanner.char_at(offset)` | (c) and parameter facts | (c), plus `offset >= 0` and small from the callers (always a literal 1, 2 or 3) |
| **e** | `MEMBER_X[Int(kind)]`, `LAYOUT[Int(kind)]`: a 352-entry table indexed by an enum's backing integer | none of these (a cheap type rule) | the enum has exactly 352 variants |
| **hash** | probe loops: `@name_slots[i]` with `i = key & (@name_slots.len - 1)`, binding tables, `NameTable` | (c) between methods | `nonempty(@name_slots)`, an invariant `grow_name_slots` keeps. The mask rule exists but needs `nonempty` |
| **ctr** | counters: `count.* += 1`, `@symbol_count += 1` | none | a bound on the count |
| **std** | std.utf8 (`multi_after`, `long_after`), std.text, the sort, the prelude's Map: checks on parameters | none | parameter facts, or offsets the guards bound by a variable (`i + n <= s.len`, `n >= 2`) |
| **data** | decoding the prebuilt libs (`Reader.u32`, bytes at `@at`) and SIMD reads | none | an index from decoded data |
| **zig** | Zig's std and Rig's runtime (wyhash, the allocator, `rig.slice`, `String.ofText`) | none | not Rig source |
| **cold** | the deliberate `_ = s[i]` of `class_end` and `find_any` | none needed | does not run |
| **other / unk** | local shapes the pass misses (an index from a call's result, as in `skip_ascii_trivia`'s `text[p]` with `p` from `class_end`), and branches the compiler merged onto line 0 | – | – |

## Results: webpack --noCheck (the ceiling's profile, 20 runs)

| category | share of all check branches (weighted) | share of live | ~share of c1 cycles | branches | sites | kinds |
|---|---:|---:|---:|---:|---:|---|
| d | 27.6% | 30.7% | 1.53% | 2427 | 313 | index 27.6 |
| d-rec | 7.6% | 8.4% | 0.42% | 712 | 38 | index 4.7, ovf 1.7, slice 1.3 |
| b+ | 8.1% | 9.0% | 0.45% | 305 | 68 | index 6.2, ovf 1.9 |
| b-built | 7.8% |  | ~0 | 566 | 60 | index 7.8 |
| a | 7.6% | 8.5% | 0.42% | 1046 | 37 | conv 7.4, ovf 0.2 |
| a+ | 5.8% | 6.5% | 0.32% | 838 | 17 | conv 5.7, ovf 0.1 |
| c2n | 2.4% | 2.7% | 0.14% | 24 | 3 | index 2.4 |
| c2r | 4.5% | 5.0% | 0.25% | 197 | 58 | slice 3.3, ovf 1.1 |
| c2p | 1.5% | 1.7% | 0.08% | 49 | 2 | index 0.8, ovf 0.7 |
| e | 0.7% | 0.8% | 0.04% | 128 | 39 | index 0.7 |
| hash | 2.2% | 2.4% | 0.12% | 211 | 20 | index 1.4, ovf 0.5, conv 0.3, slice 0.1 |
| ctr | 0.4% | 0.4% | 0.02% | 70 | 10 | ovf 0.4 |
| std | 3.9% | 4.3% | 0.22% | 655 | 126 | index 2.0, ovf 1.2, shift 0.3, conv 0.2 |
| data | 1.1% | 1.3% | 0.06% | 379 | 21 | bytes 0.8, ovf 0.2, index 0.1, slice 0.1 |
| zig | 9.0% | 10.0% | 0.50% | 1068 | 338 | zbounds 3.6, ovf 2.2, zslice 1.7, len 0.9 |
| cold | 2.2% |  | ~0 | 6 | 3 | index 2.2 |
| other | 6.1% | 6.8% | 0.34% | 858 | 404 | index 2.9, ovf 2.0, slice 0.9, conv 0.3 |
| unk | 1.4% | 1.6% | 0.08% | 172 | 46 | index 1.0, conv 0.2, ovf 0.2, slice 0.1 |

Top helpers per category (share of all weighted check branches; Rig source):

- **d**: `Ast.kind` 5.44% (ast/ast.rig:400), `Ast.parent_list` 2.89% (ast/ast.rig:876), `Ast.finish_node` 2.06% (ast/ast.rig:795), `Ast.parent_child` 1.47% (ast/ast.rig:870), `Ast.flags` 1.32% (ast/ast.rig:404), `Ast.set_parent_in_immediate_children` 1.07% (ast/ast.rig:859)
- **d-rec**: `Ast.word_node` 1.83% (ast/ast.rig:676), `Ast.parent_list` 1.45% (ast/ast.rig:876), `Ast.list_node` 1.05% (ast/ast.rig:460), `Ast.word_list` 0.80% (ast/ast.rig:680), `Ast.nodes` 0.60% (ast/ast.rig:430), `Ast.text_of` 0.48% (ast/ast.rig:484)
- **b+**: `Ast.word` 2.47% (ast/ast.rig:444), `Binder.bind_children_of` 2.24% (binder/children_generated.rig:14), `Ast.parent_child` 1.64% (ast/ast.rig:870), `Ast.parent_list` 1.45% (ast/ast.rig:876), `Ast.set_parent_of_children` 0.33% (ast/ast_generated.rig:937)
- **b-built**: `Ast.binary_expression` 2.70% (ast/ast_generated.rig:6198), `Ast.jsdoc_parameter_or_property_tag` 0.73% (ast/ast_generated.rig:6768), `Ast.source_file` 0.65% (ast/ast_generated.rig:6698), `Ast.module_declaration` 0.51% (ast/ast_generated.rig:6703), `Ast.call_expression` 0.46% (ast/ast_generated.rig:6253), `Ast.element_access_expression` 0.31% (ast/ast_generated.rig:6248)
- **a**: `Ast.new_node` 3.87% (ast/ast.rig:501), `Ast.add_text` 0.94% (ast/ast.rig:506), `Ast.add_list` 0.79% (ast/ast.rig:645), `Binding.new_table` 0.37% (ast/binding.rig:137), `Binder.new_flow_list` 0.36% (binder/binder.rig:727), `Binder.new_symbol` 0.31% (binder/binder.rig:333)
- **a+**: `Ast.finish_node` 4.05% (ast/ast.rig:795), `Ast.add_list` 0.91% (ast/ast.rig:645), `Parser.token_piece` 0.44% (parser/jsdoc.rig:1264), `Ast.add_text` 0.30% (ast/ast.rig:506), `Parser.skip_whitespace_or_asterisk` 0.06% (parser/jsdoc.rig:346), `Ids.of` 0.05% (compiler/ids.rig:83)
- **c2n**: `Scanner.char` 2.41% (lexer/scanner.rig:678), `Scanner.scan_js_doc_comment_text_token` 0.02% (lexer/scanner.rig:1613)
- **c2r**: `Scanner.scan` 2.04% (lexer/scanner.rig:770), `Scanner.token_value` 0.81% (lexer/scanner.rig:463), `Scanner.scan_operator` 0.51% (lexer/scanner.rig:844), `Scanner.value_add` 0.32% (lexer/scanner.rig:488), `Scanner.scan_js_doc_token` 0.21% (lexer/scanner.rig:1655), `Scanner.scan_comment` 0.21% (lexer/scanner.rig:1101)
- **c2p**: `Scanner.char_at` 1.50% (lexer/scanner.rig:684)
- **e**: `Ast.expression` 0.11% (ast/ast_generated.rig:7596), `Ast.name` 0.11% (ast/ast_generated.rig:7582), `Ast.modifiers` 0.10% (ast/ast_generated.rig:7589), `Ast.deep_clone` 0.09% (ast/deepclone.rig:22), `Ast.statement_list` 0.07% (ast/ast_generated.rig:7694), `Ast.argument_list` 0.06% (ast/ast_generated.rig:7631)
- **hash**: `Ast.place_name` 0.95% (ast/ast.rig:554), `Binding.table_put` 0.36% (ast/binding.rig:173), `NameTable.place` 0.26% (ast/names.rig:279), `Binding.table_get` 0.20% (ast/binding.rig:154), `Names.rebuild` 0.17% (ast/names.rig:178), `Names.find_in` 0.10% (ast/names.rig:194)
- **ctr**: `make_identifier` 0.18% (parser/parser.rig:155), `Binder.new_symbol` 0.16% (binder/binder.rig:333), `Parser.parse_tag_comments` 0.01% (parser/jsdoc.rig:446), `Parser.find_matching_parameter` 0.01% (parser/reparser.rig:610), `Parser.parse_jsdoc_comment_worker` 0.01% (parser/jsdoc.rig:183), `FileLoader.add_sub_task` 0.00% (compiler/filesparser.rig:318)
- **std**: `long_after` 0.74% (std/utf8.rig:59), `Map(u32,u32).put` 0.46% (?), `find_any` 0.42% (?), `multi_after` 0.39% (std/utf8.rig:43), `order2_cmp_func` 0.22% (?), `partial_insertion_sort_cmp_func` 0.20% (?)
- **data**: `Reader.u32` 0.51% (ast/prebuilt.rig:290), `Scanner.find_comment_close` 0.27% (lexer/scanner.rig:1172), `Reader.list` 0.12% (ast/prebuilt.rig:283), `Reader.int` 0.07% (ast/prebuilt.rig:300), `Reader.u32_list` 0.04% (ast/prebuilt.rig:360), `Reader.nodes` 0.03% (ast/prebuilt.rig:320)
- **zig**: `wyhash.Wyhash.final1` 1.29% (?), `wyhash.Wyhash.read` 1.29% (?), `wyhash.Wyhash.smallKey` 0.97% (?), `runtime.slice` 0.56% (?), `alloc.Heap.alloc` 0.33% (?), `wyhash.Wyhash.hash` 0.32% (?)
- **cold**: `class_end` 2.05% (std/text.rig:100), `find_any` 0.14% (?)
- **other**: `Scanner.skip_ascii_trivia` 1.02% (lexer/scanner.rig:737), `Binding.index_flow_runs` 0.59% (ast/binding.rig:284), `Parser.parse_delimited_list_opt` 0.39% (parser/parser.rig:761), `Scanner.last_line_start_before` 0.34% (lexer/scanner.rig:1188), `Scanner.process_comment_directive` 0.26% (lexer/scanner.rig:1282), `Scanner.scan_js_doc_comment_for_tags` 0.21% (lexer/scanner.rig:609)
- **unk**: `Ast.text` 0.50% (ast/ast.rig:698), `Binder.bind_declaration` 0.22% (binder/binder.rig:848), `Parser.parse_postfix_type_or_higher` 0.06% (parser/parser.rig:2739), `Parser.parse_statement` 0.06% (parser/parser.rig:1108), `Parser.parse_non_array_type` 0.06% (parser/parser.rig:2775), `Scanner.scan_js_doc_token` 0.05% (lexer/scanner.rig:1655)



## Results: webpack full (10 runs, recorded for this census)

Not recorded. `census/record-full.sh 10` (10 Time Profiler runs of `c8-check/A/bin` on webpack
full, exported for `tools/leaf.py`) waited 32 minutes under `tools/mac-claim` while back-to-back
c8 A/B claims held the Mac (`c8-ab-tasks`, `-actors`, `-net`, `-http`), and I stopped it. To add
it, run `tools/mac-claim --minutes 15 rig-census-prof census/record-full.sh 10`, then
`tools/leaf.py census/full.tsv census/xml/*.xml`, `tools/sites.py`, `tools/sitetext.py`,
`tools/classify.py`, and `tools/report.py` with the full run's measured check cost (6.8%).

What this leaves out: on full runs the checker takes most cycles (webpack 3.2B cycles against 0.8B
with --noCheck), and none of its checks are weighted here. By static count (below) the checker's
remaining checks are mostly handle indexes, category d, such as `store.types.at(t)` and
`small_kinds.at(types.at(t).data)`. Its handles are already bounded slot types
(`rig.SlotOf(2^27)`), but they index Lists, so each index is still tested. Category d's share is
therefore probably larger on full runs. The shares of (a), (b) and (c), which sit in the
parser, lexer and binder, are probably smaller.

## Static counts (emitted Zig of each module, check operations left, by category)

| category | parser | lexer | ast | binder | checker |
|---|---:|---:|---:|---:|---:|
| a | 0 | 0 | 68 | 14 | 90 |
| a+ | 7 | 0 | 22 | 0 | 30 |
| b+ | 0 | 0 | 117 | 114 | 0 |
| b-built | 0 | 0 | 2 | 0 | 1 |
| c2n | 0 | 2 | 0 | 0 | 0 |
| c2p | 0 | 3 | 0 | 0 | 0 |
| c2r | 6 | 176 | 0 | 0 | 0 |
| ctr | 4 | 2 | 1 | 2 | 19 |
| d | 3 | 0 | 418 | 84 | 1803 |
| d-rec | 0 | 0 | 221 | 0 | 2 |
| data | 0 | 0 | 73 | 0 | 0 |
| e | 0 | 0 | 82 | 0 | 1 |
| hash | 0 | 0 | 57 | 0 | 0 |
| other | 256 | 379 | 489 | 56 | 3776 |
| all | 276 | 562 | 1551 | 270 | 5722 |


These are static operation counts. They give the size of each category, not its cost.
`classify.py` was tuned on the parser, lexer, ast and binder sites. In the checker, "d" is every
`self.<list>.at/slot/constSlot(x)` whose argument is a bare name or another list's field, and
"other" is mostly its overflow-checked arithmetic and conversions, which I did not classify by hand.

## The rules, ordered by payoff per unit of compiler work

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

