# Audit: std text and data modules, and the hash tables

Scope, read in full at `revamp` (base edc481031): src/ordered.zig,
src/unordered.zig, std/prelude.rig, std/text.rig, text.zig, char.zig,
utf8.rig, utf16.rig, unicode.rig, json.rig, terminal.rig, terminal.zig,
bigint.rig, bigint.zig, crypto.zig, crypto/aead.rig, crypto/aead_test.rig,
crypto/ct.rig, sort.rig, math.rig, math.zig, random.rig, random.zig,
slices.rig, iter.rig, hint.rig/zig, target.rig/zig, embed.zig; the
generators' headers of char_tables.zig, width_tables.zig,
unicode_tables.zig; docs/STD.md for these modules; docs/design/terminal.md;
INTERNALS "The built-in Map and Set" and "The built-in HashMap and
HashSet". No tracked file was changed. Probes ran from a scratch folder
with `bin/rig` (built Nov 3 05:51) and `RIG_STD=$PWD/std`.

Probes that back findings below:

- `e.text` on `json.Error.utf8` prints `utf8`, as `json.error_name` does;
  `b == '['` and `b == "["` both work on a `U8`; `Int.wrap(U64.max)` is
  -1 and `U64.wrap(-1)` is 18446744073709551615; a function returning
  `(Int, U64)` works; a module constant `T_A = 3` matches as a `match`
  pattern (and `x = 4` falls to `_`).
- `unicode.is_space(0x200A)` is true and `(0x200B)` false: the
  `0x2000..0x200B` arm is exclusive, as it should be.
- std.terminal, release build, 80x24, no scrollback: N truecolor SGRs
  (`ESC[38;2;r;g;bm` + `x`) then `e` + N U+0301. N = 200,000: max RSS
  28.8 MB. N = 2,000,000: max RSS 203 MB, and `dump` is 4,039,299 bytes,
  nearly all of it the one cell holding 2,000,000 combining marks.

No finding is a memory-safety bug in safe code. I looked hardest at the
places where one would hide: the tape packing and number parsing of
std.json, the Eisel-Lemire port (it matches Rust's `dec2flt::lemire`
step for step), the in-block UTF-8 checks in json's `utf8_text` and in
utf8's `rune_count`, bigint's Möller-Granlund division (1e19 is a
normalized divisor), and the ordered table's `retain` when `f` panics.
That last one is not reachable: under `task.isolate` the half-changed
Map is `f`'s own and is never dropped or read again (SPEC "Isolating a
panic"), and a `Cell` only swaps whole values.

## Findings

Most severe first. Net LOC is the estimated change in lines (negative
removes lines).

| ID | file:line | Category | Severity | Finding | Evidence | Proposed fix | Est. net LOC | Risk |
|---|---|---|---|---|---|---|---|---|
| S1 | std/terminal.rig:211-222, 618-624 | resource bound / DoS | High | Program output, which is untrusted input, can grow a Terminal's memory without bound in two ways. (a) `intern` pushes every new style onto `styles` and `style_ids`, and nothing ever removes one: only RIS (`full_reset`, :526) starts over. (b) `append` adds every zero-width rune to the cell's `extras` list with no cap. | Every write of `styles` is at :220 and :221 (grep); `append` has no limit. Probe: 2M SGRs plus 2M U+0301 reach 203 MB RSS (28.8 MB at 200k), and one cell's dump is 4 MB. | Cap the runes in one char (read Ghostty's grapheme storage at the pin for its limit, and match it), dropping runes past the cap. For styles, either keep a use count per style, as Ghostty's style sets do, or rebuild the table when `styles.len` passes a limit by remapping the live cells' marks (history included). Both are Ghostty-conformance changes, so they must go through `tools/terminal_ghostty.py --fuzz`. | +40 | medium: conformance and speed (styles rebuild on the truecolor corpus) |
| S2 | src/unordered.zig:342; src/runtime.zig:2179, 2184-2186, 2208-2211 | security (hash flooding) | High | An Int key in a HashMap hashes as `k * int_mul`, with no seed. That is a bijection an attacker can invert: the keys `c * inverse(int_mul)` hash to the chosen `c`, so a set of keys can share one home group and one tag, and every lookup then compares every key. Map, Set, and text keys use `rig.hash`, whose seed is the fixed `0x2d35…` and whose text seed is 0. STD documents the risk for Map (STD.md:1920-1922) but not for HashMap (STD.md:1992-2005). Programs that take keys from the network (std.http, std.json object keys) inherit it. | The cited lines. | Draw one seed from the operating system per process at runtime start. XOR it into the integer hash before the multiply and pass it as Wyhash's seed and `hash_seed`. A Map's order is insertion order, so its output does not change; a HashMap's order is already unspecified. The extra work is one load and one xor, but `bench/hash/guard.py` must stay within 2%. Until then, document the HashMap risk. | +15 | medium: guard rows; any test that prints a HashMap of several entries in slot order |
| S3 | std/crypto/aead.rig:14-18; docs/STD.md:1423-1425; std/crypto/x25519/x25519.rig:40-51 | crypto constant time | Medium | The AEADs (and BLAKE2s, per STD) run without Arm's DIT, while x25519 sets it. STD says "the AEADs and BLAKE2s do not need it", and aead.rig says add, xor, shift, and multiply "take the same time whatever their operands on the cores Rig targets". Arm guarantees data-independent timing for those instructions only while DIT is set, and Apple's guidance is to set it for cryptography. The claim is an assumption about today's cores, not a guarantee. | The cited lines. `dit_on` and `dit_restore` exist in std/crypto.zig:40-61. | Wrap `seal_with`, `open_with`, `*_into_with`, and the BLAKE2s compress in `dit_on`/`dit_restore`, as x25519 does, and measure a 64-byte open, which the `state` comment shows is cost-sensitive (aead.rig:295-297). Otherwise reword both docs to say no architectural guarantee holds without DIT. | +12 | low |
| S4 | std/json.rig:126-141, 46-68, 162-163, 690-692 | dead code / stale workaround | Medium | Four `NEEDS` workarounds name capabilities Rig now has. `error_name` (an enum variant's name) is `e.text` (STD.md:2307; probe). The byte constants (`TAB`, `QUOTE`, …, "character literals") can be `'"'` and `"\n"` as `U8`, as terminal.rig already writes them (:1692, :1702). The `kind` arms use literals because "a match takes no named constant", but one does (probe). `take_digits`'s out-parameter stands in for multiple results, which exist (aead.rig:452-456; probe). | Probes above. | Make `error_name` a one-line alias of `e.text`, kept for the callers in test/rig/std-misc.rig.test and examples/json_tour.rig, then remove it after migrating them. Write the bytes as literals and the `kind` arms with `T_*`. Leave `take_digits` alone unless a tuple return keeps json's guard; re-mark it with the real reason, register allocation. | -45 | low, except take_digits (guard) |
| S5 | std/utf8.rig:226-282; std/utf16.rig:129-164; std/json.rig:831-882 | duplication | Medium | Three copies of the Keiser-Lemire UTF-8 block check, the same three nibble tables bit for bit (json's `BYTE_1_HIGH` equals utf8's `BY_FIRST_HIGH`: 0x02×8, 0x80×4, 0x21, 0x01, 0x15, 0x49), plus `ENDS` and `lanes_sum` twice. utf16 already does `use std.utf8`. | The cited lines. | Make utf8's `errors`, `ENDS`, and `lanes_sum` public (as `utf8.block_errors` and so on) and call them from utf16 and json. json's `utf8_errors` is the same function with `& 0x80` in place of `select`. | -85 | low; json guard |
| S6 | std/json.rig:898-907, 803-829; std/utf8.rig:478-485, 43-66; std/terminal.rig:800-826; std/char.zig:183-211 | duplication | Medium | Four UTF-8 decoders and two identical encoders. json's `push_utf8` is utf8's `push_multi` byte for byte. json's `utf8_end` re-does `multi_after`'s range table as a `match`. terminal's `print_utf8` inlines a fifth decoder. char.zig's `decode` is the Zig twin of `rune_after`, needed because a shim cannot call Rig. | The cited lines. | Export `utf8.push_rune_unchecked` (the body of `push_multi`) and a `utf8.sequence_end(s, i) -> Int` (`multi_after` returning `-1`, not `bad()`). Use them in json and terminal. Keep char.zig's decoder. | -60 | medium: json and terminal speed (re-measure bench/json and bench/terminal) |
| S7 | std/text.rig:541-544, 637-643 | hot-path performance (Trig) | Medium | The Interner's open-addressed table is rebuilt only past 4/5 full (`@len * 5 <= tags.len * 4`), though `id_table_size` sizes it to at most 2/5 and its comment says so. Linear probing at 0.8 load costs about 13 probes for a miss, against about 1.9 at 0.4. Trig's checker and its names table use `text.Interner` (trig/src/checker/checker.rig, src/ast/names.rig). | The cited lines. | Rebuild at 1/2 (or at 2/5, as the comment says), or reuse the ordered table's 16-tag groups. Time on Trig before choosing; a grow costs a rebuild. | ±2 | low |
| S8 | std/text.zig:14-20, 337-340; std/bigint.zig:1-17; std/math.zig:49-51; std/random.zig:13-15; std/char.zig:42, 48, 58 | concision / false comment | Medium | Six Zig shims exist only to panic. bigint.zig's header says Rig "has no way to raise" a panic, but Rig code panics directly: prelude.rig:142, :428 and aead.rig:134, :154, :178. | The cited lines. | Replace each with `panic("…")` in Rig. Delete std/bigint.zig and its embed.zig line, and the `extern` entries. `check_range`'s message interpolates `lo` and `hi`, which needs `String(…)` or a fixed text. | -50 | low |
| S9 | std/iter.rig:1-17 | duplication (one mechanism per idea) | Low-Medium | `iter.count` and `iter.sum` are chain consumers that already exist with no import, `(!it).count()` and `.sum()` (SPEC.md:6255+ "Chains"), and STD.md:1641-1644 says so. The one difference is that `iter.sum` gives `none` when empty and the chain gives 0. | grep: used only by 4 test files and docs/learn/08-apis.md. | Remove std.iter and migrate the 4 tests. If an empty-aware sum is wanted, add it to chains. | -17 (+tests) | low |
| S10 | std/slices.rig:11-19; std/sort.rig:120, 134 | API / ownership | Medium | `contains`, `index_of`, `lower_bound`, and `search` take the needle by value, `x: T`, and `contains` moves it (`<x`). To search a `List[String]` the caller must give up or clone a String, while every other lookup in std takes a view (`Map.has(k: ?K)`, `text.find(pat: ?String)`). | The cited lines. | Take `x: ?T`. | 0 | low (callers pass a view) |
| S11 | std/random.rig:59-65 | North Star 2 (raw in std) | Low-Medium | `as_u64` and `as_int` use `raw $bitCast` for what `U64.wrap(n)` and `Int.wrap(x)` do safely (probe), as utf16.rig:34 and bigint.rig:235 already write. std should hold no `raw` it does not need. | Probe: `Int.wrap(U64.max) == -1`. | Use `U64.wrap` and `Int.wrap`, and delete both functions. | -8 | none |
| S12 | std/math.rig:83; std/math.zig:55-73 | performance | Low | `shortest` runs the whole Ryu conversion twice: `shortest_digits(f)` and `shortest_exp(f)` each call `decimalOf`. | The cited lines. | Return both values from one shim, packed as `digits` plus `exp` in a U128, or have the shim fill a `Decimal`. | -3 | none |
| S13 | std/utf8.rig:286-295 | performance | Low-Medium | `is_valid` checks a rune at a time (fast only on ASCII runs), while `rune_count` in the same file checks 64 bytes at a time with the vector check. | The cited lines. | Write `is_valid` as `rune_count`'s block loop that returns false at the first faulty block, then run the scalar tail. | +5 (shared with S5) | low |
| S14 | docs/STD.md:179-180 vs std/bigint.rig:4-5 | doc mismatch | Low | STD says every operation "allocates one List … even when the result is zero". The code (`zero()`, `from_int(0)`) and the module header say "none for zero". | The cited lines. | Fix STD. | 0 | none |
| S15 | std/text.rig:10-11 | doc mismatch | Low | The header says the chars follow "the tables of Unicode 15.1", but char_tables.zig is 17.0.0 (its header, `version = "17.0.0"`), as STD.md:2559 says. | The cited lines. | Say 17.0.0, or name `unicode.VERSION`. | 0 | none |
| S16 | std/text.rig:4-7; docs/STD.md:2380-2381 | doc mismatch | Low | "Nothing here allocates but `format_int` … and `edit_distance`", but `chunks` (:213) returns a new List, and `Interner` (:521) allocates. | The cited lines. | List them. | 0 | none |
| S17 | docs/STD.md:1904-1909 | doc mismatch | Low | The Map's internals paragraph is stale. It says the entries are "kept in one List" (they are a raw block, ordered.zig:171); that the hash is kept unless "the keys and values are plain data" (the rule is the key's size and word count only, ordered.zig:90); and that an entry "is `none` once taken" (gone entries are a bitset, ordered.zig:136-138). | The cited lines. | Rewrite it from ordered.zig's header. | 0 | none |
| S18 | docs/internals/INTERNALS.md:5487 vs src/unordered.zig:311-314 | doc mismatch | Low | INTERNALS says the slot prefetch applies to "slots of 32 bytes or fewer"; the code and its comment say 40. | The cited lines. | Say 40. | 0 | none |
| S19 | src/ordered.zig:779-785, 816, 827; src/unordered.zig:806, 817; src/ordered.zig:804 | stale comments | Low | `dropEntry` has two doc comments, and the first ("The last entry written, `j`, cut off …") is an orphan. Four doc comments end in a stray `///` run into the next sentence. ordered.zig names `resolve.registerBuiltins`, but the registration is `registerTables` (resolve.zig:5331), as unordered.zig:794 says. | The cited lines. | Delete the orphan, split the lines, and fix the name. | -3 | none |
| S20 | src/ordered.zig:316-324, 328 | limit mismatch | Low | Growth doubles the room, so at 2^31 entries the next room, 2^32, is past `max_entries` and `tooMany` panics. A Map grown by `put` therefore holds at most 2^31 entries, though the panic message and STD say 4,294,967,295. Only `reserve` reaches the stated limit. | The cited lines. | Clamp `nextRoom` to `max_entries`, or state 2^31. | +1 | none |
| S21 | src/ordered.zig:1064-1068 | performance | Low | After `retain` on a small table, `reindex` hashes every key again to remake the tags, though `retain` already zeroed the gone lanes and `compactSmall` (:560-570) moves the tags with their entries. For String keys that is a Wyhash per kept key. | The cited lines. | Call `compactSmall` for a small table. | -3 | low |
| S22 | std/prelude.rig:109-125, 135-145, 399-413, 423-431; src/ordered.zig:921-925; src/unordered.zig:926-933 | performance | Low | `ensure_with` and `ensure_by` hash the key twice when it is new: once for `find` or `edit`, and again in `insert_new`. For text keys that is a second Wyhash. This is the `rarely` path. | The cited lines. | Have the table's lookup hand back the hash, or give it an `insert_new_hashed(k, v, h)`. | +6 | low (guard) |
| S23 | std/prelude.rig:257-322, 526-567 | duplication | Low | Four ordered iterators repeat the same run-walking body (7 lines each), and four Hash iterators repeat the `next_slot` call. `Set.items` (:251) inlines `first_end`. | The cited lines. | One `Cursor` object (`next_at`, `end`, `holes`) whose `step(?t) -> Int` the four `next`s call, and the same for the hashed walk. Check that the walk stays one counted loop (bench/hash walk rows). | -25 | medium (walk speed) |
| S24 | src/ordered.zig:111-130; src/unordered.zig:272-292, 455-458, 68 | duplication | Low | `dropValue`, `cloneVal`, `dropKey`, `cloneKey`, `tooMany`, and `max_entries` are the same in both tables, and so are the test closures (`F`, `keep`). | The cited lines. | Move them into runtime.zig as `rt.HeldOps(K, V, key_align, val_align)`. | -30 | none |
| S25 | std/char.zig:140, 151, 169, 127-132 vs 156-161 | duplication | Low | Three copies of the clamp "not a rune → U+FFFD", and `char_step_width` re-does `classOf`'s tailoring switch. | The cited lines. | Add `fn runeOf(r: i64) u21` and `fn tailor(c, cp)`. | -12 | none |
| S26 | std/terminal.rig:17-26, 200 | coupling | Low | terminal.rig declares char.zig's externs a second time (text.rig:503-506 has `char_step`), and hard-codes `CLASS_PICT = 1`, the position of `.pict` in a generated Zig enum. | The cited lines. | Have char.zig export `is_pict(r)`, or make `char_class` return a Rig enum. | -2 | low |
| S27 | std/terminal.rig:501-516 | input validation | Low | `Terminal.new` accepts `cols <= 0` or `rows <= 0`, and the first `feed` then panics on an index deep in `print` (`bottom` is -1). | The cited lines. | Panic in `new` with a clear message. | +2 | none |
| S28 | std/terminal.rig:450-454 | stale comment | Low | Two comments for `modes`/`saved_modes`, the first a leftover of the second. The comment at :434-435 lists modes that are declared further down, after the protection fields. | The cited lines. | Delete the first and move the second. | -2 | none |
| S29 | std/text.rig:386-389, 633-635 | performance | Low | `edit_distance` resizes `row` by popping and pushing one at a time, and `IdTable.reset` pushes `n` zeros one at a time. | The cited lines. | `List.filled`, or `resize(n, 0)` as terminal.rig:1023 does. | -4 | none |
| S30 | std/text.zig:26-28 | performance | Low | `find_last` goes to `std.mem.findLast`, which is scalar for needles of 4 bytes or fewer (Zig 0.17 mem.zig:1578), while `find` is vectorized. | The cited lines. | A reverse `byteFrom` for one byte; the pair test, mirrored, for more. | +40 | low |
| S31 | std/sort.rig:16-27, 40-41, 120-145 | performance / duplication | Low | `sort_by` is SymMerge (insertion runs of 20 swapped one by one, then merges by rotation), with O(n log² n) swaps. A private `min` duplicates `math.min`, and `search` repeats `lower_bound`'s loop. | The cited lines; STD.md:1522-1524. | `search` = `lower_bound` plus a test. Offer a merge that takes a scratch buffer, as `edit_distance` takes `row`. | -10 | low |
| S32 | std/random.rig:40, 45 | performance | Low | `int` divides twice (`%`) per draw. | The cited lines. | Lemire's multiply-and-reject. | 0 | low (sequence changes: seeded outputs in docs) |

## API consistency

| Module | Inconsistency | Proposed name / shape |
|---|---|---|
| json | Constructor `json.new_doc()`. Elsewhere it is `T.new()`, `T()`, `T.seeded`, `T.of`. | `json.Doc()` or `json.Doc.new()` |
| json | `doc.size()` counts entries. Every other container has `len` (List, Map, Interner, String). | `doc.len` |
| json | `get_bool`, `get_int`, `get_float`, `get_str`. Elsewhere `get` is a keyed lookup that returns `T?`, and `str` is the only abbreviation of "string" in std (the `Kind` variant is `string`). | `doc.bool(i)`, `doc.int(i)`, `doc.float(i)`, `doc.string(i)` |
| json | Two ways to fail: `parse -> Bool` plus `error`/`error_pos` fields, and `load` with `JsonError.bad(kind, at)`; the error-kind enum is named `Error`. Every other parser fails with an error set. | `load` alone (or `parse -> ()!JsonError`); rename `Error` to `JsonError.Kind` |
| text, bigint, json | Three parse-error shapes: `text.ParseError{invalid, overflow}`, `bigint.ParseError{invalid}` (a second type with the same name), and json's. | One `std.text.ParseError` that bigint fails with too |
| text, bigint | `compare -> Int` (-1/0/1) while the language has `Order` (`x.order(?y)`, `.less`). | `compare -> Order` (`text.order(a, b)`, `a.order(?b)`) |
| bigint, crypto | `a.equals(b)` vs `crypto.equal(a, b)`: two spellings of one idea. | `equal` in both |
| bigint | `to_f64` names a Zig/Rust type; Rig's is `Float`. | `to_float` |
| math | `pow` (Int) and `powf` (Float) vs `sqrt`, `exp`, and the others, which carry no suffix. | `math.pow` for Int and Float via `[T: Num]`, or `math.powf` renamed `math.fpow`; owner's call |
| sort, slices | The needle is taken by value (S10); Map/text take views. | `x: ?T` |
| prelude | Map puts `t` before `len` (prelude.rig:41-45), HashMap `len` before `t` (:333-336). The ordered field order was measured (ordered.zig:165-168); the unordered one was not. | Same order in both, or a comment saying why not |
| prelude / tables | `OrderedMap.ensure -> Int` with the prelude storing `@len = @t.count()`, vs `UnorderedMap.ensure(k, v, len: !Int) -> !V`, which writes the HashMap's `len`. The same built-in member has two shapes. | One shape: both return the value's pointer and take `!len`, or both return an index |
| panics | Argument panics raised from Zig shims (text, bigint, math, random, char) vs `panic(…)` in Rig (prelude, aead). | `panic` in Rig everywhere (S8) |
| utf8 / text / json | Three private copies of "is ASCII digit" and of `ONES64`/`HIGH` (json.rig:610, :742; text.rig:108-109; utf8.rig:447). | Use `text.is_digit`; one set of SWAR constants in utf8 |
| text / bigint | Two digit-pair formatters with the same `PAIRS` table (text.rig:337-370, bigint.rig:482-520). | `text.push_int(out: !String, n)`, used by `format_int`, bigint, and terminal's `out.add(c)` |
| terminal / text | `history_row(i) -> String` allocates per call, while the dump helpers append to an `out`. | Add `history_text(i, out: !String)` publicly; keep `history_row` as sugar |

## Restrictions and rules

| Rule (where stated) | Serves the North Star? | Judgment |
|---|---|---|
| text reads `?String` as UTF-8 by convention and checks nothing (text.rig:1-3) | Yes: zero hidden cost; invalid bytes read as U+FFFD, Go's rule | Keep |
| Every index outside `0..len` panics "as indexing does" (find_any, class_end, ascii_end, rune_after) | Yes: correctness | Keep; the `_ = s[i]` idiom repeats in 4 places, so a `check_cursor(s, i)` helper would serve |
| A Float has no `Ord` and is no Map key | Yes: correctness (NaN) | Keep |
| BigInt has no `==` or `<` "which would hide a walk over the limbs" (STD.md:234-235) | Weak: `String ==` and `List ==` walk too, and they are allowed | Let BigInt provide `Eq`/`Ord` through its own meanings, or state the rule for every type that walks |
| Map/Set/HashMap hold at most 2^32-1 entries | Yes: u32 entry indexes halve the index | Keep; fix the 2^31 growth limit (S20) |
| The hash seed is fixed (STD.md:1920-1922) | No: determinism is already unspecified for HashMap and unaffected for Map, and the fixed seed opens hash flooding (S2) | Seed per process |
| `ensure_by` panics when `key(k) != k` (prelude.rig:142) | Yes: the alternative is a corrupt table | Keep |
| `ensure_with`/`update`/`retain` refuse a `V` that can hold a view | Yes: soundness (Core) | Keep |
| JSON: depth 1024, input 4 GiB, string 2^27-1 bytes (json.rig:72-78) | Yes: the tape packs offset and length in one Int; the limits are explicit `too_large` errors | Keep; the 128 MiB string limit is the one a user may meet; document it in the error text |
| Interner: U32 ids, `ends` as U32, so 4 GiB of text (text.rig:525, 537) | Yes | Undocumented; state it in STD, and make the panic say so |
| sort allocates nothing (sort.rig:9, STD.md:1522-1524) | Partly: no hidden allocation, but at O(n log² n) swaps | Keep the default; add a scratch-taking merge (S31) |
| Terminal: history reserves up to `min(scrollback, 65536) * cols` cells at the first scroll (terminal.rig:1015-1022) | Visible in design/terminal.md, not in STD: about 16 MB at 200 columns and the default scrollback | Say it in STD's `Terminal.new` row |
| Terminal: MAX_PARAMS 24, MAX_PARAM 65535 | Yes: Ghostty parity, bounded work per sequence | Keep |
| Terminal: no bound on styles or on runes per cell | No (S1) | Add bounds |
| AEADs and BLAKE2s run without DIT (STD.md:1423-1425) | No, as stated (S3) | Set DIT, or soften the claim |
| crypto `below` is "never a branch, in any build" (crypto.zig:94-98) | Holds for LLVM's lowering of `@intFromBool(a < b)` today; it is not a guarantee | Keep, but word it as observed codegen and test it with a `code` case on the emitted asm |
| terminal.zig exists because Zig 0.17's LLVM loop vectorizer is off (terminal.zig:1-7) | Yes: measured 35% | Keep until Zig 0.18, as the ROADMAP says |
| utf8 functions read every input as their Go twin does | Yes: one well-known rule | Keep |
| A module's Zig shim must raise its argument panics (bigint.zig:1-2) | No: Rig has `panic` (S8) | Drop the rule |

## The biggest simplification

std carries one UTF-8 engine five times. The Keiser-Lemire block check
is copied in utf8, utf16, and json; a sequence decoder is written out
in utf8, json, terminal, and char.zig; the encoder exists in utf8 and
json; and four hand-tuned "first byte of a class, 16 at a time, then
re-read the last 16" scanners live in text (`find_any`), utf8
(`ascii_end`), json (`skip_plain_ascii`), and terminal
(`printable_end`). Making utf8.rig the one owner of validation,
decoding, and encoding (public `block_errors`, `sequence_end`,
`push_rune_unchecked`, and a block-scanned `is_valid`), and having
json, utf16, and terminal call it, removes roughly 200 lines and
leaves one place to prove and test. Add the json `NEEDS` workarounds
that Rig has since outgrown (S4, about 45 lines) and the six panic-only
Zig shims (S8, about 50 lines and one file), and a large part of the
surface this audit read goes. The guard numbers for std.json and std.text
and bench/terminal decide whether each step lands; S5 and S8 carry
almost no speed risk and can go first.
