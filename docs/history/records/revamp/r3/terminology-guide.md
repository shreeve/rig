# Terminology guide: lend, view, loan (REVAMP-3, HANDOFF step 7)

*You lend a view; the compiler remembers the loan.* (docs/CORE.md:21)

This guide plans step 7, "the vocabulary pass": one change that rewrites
every remaining "borrow" in diagnostics, test expectations, comments,
internal names, the grammar, and every document into **lend**, **view**,
and **loan**, by meaning, then adds a lint that fails on any stray
"borrow". It changes no behavior.

- Census base: worktree `/Users/shreeve/Data/Code/rig-revamp`, branch
  `revamp` at `38fc9265` (main `f996dfd6` has the same 2,619 lines).
- Census command: `git grep -n -i borrow` (lines), `git grep -o -i borrow`
  (occurrences), `git ls-files | grep -i borrow` (paths).
- Steps 1-6 still add and change diagnostics before step 7 runs. Every
  file:line below is a snapshot; **the rules (§M1-§M3, §M8) are the
  contract**, and the per-string tables are their worked application.
  Re-run the census when step 7 starts; the lint (§L) catches whatever
  the tables miss.

Contents: five viewpoints (§V1-§V5), the merged guide (§M1-§M9), the
lint (§L), counts (§C), the commit plan (§P), questions for the Rig
session (§Q), appendices (per-file counts, paths).

---

## §V1. Programmer (writes Rig daily)

Question: do the rewritten diagnostics read naturally and say what to do?

Findings.

1. **The core conflict family becomes one pattern.** Today the checker
   says four different things for one event (src/ownership.zig:710-722):
   `cannot read-borrow`, `cannot write-borrow`, `cannot take a second
   write borrow on`, `while it is read-borrowed`. Rewritten, all are
   `cannot <act> `x` while a <read|write> loan is live`:
   - `cannot lend `v` to write while a read loan is live` (HANDOFF's
     exemplar; 39 test expectations, CORE:57, :253, :482);
   - `cannot lend `n` to read while a write loan is live` (CORE:237);
   - `cannot lend `v` to write while a write loan is live` (replaces
     "second write borrow", 14 + 2 expectations);
   - `cannot move `rc` while a read loan is live` (replaces
     "while it is read-borrowed", 7 expectations; the `{s}-borrowed`
     template at ownership.zig:722 becomes `while a {s} loan is live`,
     still filled by `@tagName(l.kind)`).
   A daily user learns one sentence shape and one fix: end the view's
   use first, or lend later.
2. **Drop/reassign join it:** `cannot drop `x` while borrows are live`
   (23 expectations) and `cannot reassign `x` while borrows are live`
   (14) become `... while a loan is live`. "Loans" plural invited "how
   many?"; the note names the one that blocks.
3. **The note says where the lend is.** `{s} borrow taken here`
   (ownership.zig:689) becomes `lent to {s} here` (`lent to read
   here`). Error + note read as one story:
   `cannot lend `v` to write while a read loan is live` /
   `note: lent to read here`. No test matches notes (checked:
   `git grep "taken here"` finds nothing under test/ or docs), so notes
   can be improved freely; recommended follow-up (not step 7): name the
   view that keeps the loan alive (`the loan lasts while `a` is used`).
4. **Hints must stay imperative and say what to write.** Every current
   hint keeps its fix; only the verb changes: "Borrow it instead:
   `?b` or `!b`" → "Lend it instead: `?b` or `!b`"
   (ownership.zig:2517); "to borrow the call's result, write
   `?(T.m(...))`" → "to lend the call's result, write ..."
   (typecheck.zig:6231, 6827, 6845, 7107).
5. **Receiver messages read better from the caller's side.**
   `method `bump` requires a write-borrowed receiver` (WELCOME:533,
   6 sites typecheck.zig:6877-6889) becomes `method `bump` needs its
   receiver lent to write; use `!receiver.bump(...)``. The programmer
   writes the `!` on the receiver, so "lent to write" names exactly what
   they must add.
6. **Two messages are worse with a literal swap and need a reshape:**
   - `returned borrow of `user` does not originate from a borrowed
     parameter` (14 expectations, CORE:269): a swap gives "returned view
     of `user` does not originate from a view parameter", jargon on
     jargon. Recommended: `cannot return a view of `user`, which this
     function was not lent` (it is CORE sentence 7 almost word for
     word).
   - the composed "cannot write-borrow parameter `x`" family
     (typecheck.zig:983, 1202 feed 11 templates, 1213-1266): "lend ...
     to write" needs the object in the middle, so the verb slot splits
     into a head and a tail (§M4).
7. **"Unique borrow" was the reason write views can't be copied; keep
   the reason.** `would duplicate a unique borrow; use `<w` to move it`
   → `would copy a write view, which is unique; use `<w` to move it`
   (ownership.zig:2373, 2360, 2375, 2388).

Ambiguities left to §M: "while a loan is live" vs "while it is lent"
(chosen: loan, for one pattern); "lend on" (CORE's own phrase) vs
"re-lend" (chosen: lend on).

## §V2. Newcomer (from Python, Ruby, JS)

Question: is each word clear on first contact; where would they misread?

Findings.

1. **"lend" is the clearest of the three.** Everyone has lent a book:
   you still own it, someone else uses it, you can't sell it meanwhile.
   That is the whole read/write rule. Python and JS programmers never
   learned "borrow" as jargon, so nothing is lost for them.
2. **"view" matches what Python already calls a view.** numpy slices,
   `memoryview`, and `dict.keys()` are views: they share the owner's
   memory and see its changes. A `[]T` and a `String` are exactly that.
   **Misreading risk: a "write view" sounds like an oxymoron**, since a
   view suggests looking. Mitigation: WELCOME's first mention must say
   "a view lets you use what someone else owns: read it, or, with `!`,
   change it" (WELCOME:58-59 now says only "what the receiver
   gets"). Keep "write view" in diagnostics; the type `!T` next to it
   carries the meaning.
3. **"loan" is easy to misread as the act.** In everyday English
   "loan" is also a verb ("loan me five dollars") and "a loan" is often
   the act of lending. Rule (§M1): *loan* is only ever a noun and only
   the record; never "loans `x`", never "the loan of `x` happened on
   line 4". "A loan of `x`" (CORE's "loans of everything it was lent")
   is the record that `x` is lent.
4. **"live" is liveness jargon.** "while a read loan is live" is fine
   once WELCOME says once: "a loan is live until the last use of every
   view that carries it". It already almost does (WELCOME:61-62).
5. **"lent" reads as past tense.** "`x` is lent" could read "was lent
   once". Use it only with a present frame: "while `x` is lent",
   "`x` is lent here" (a note at the lend), never "`x` was lent".
6. **"lend on" is opaque on first contact.** It is CORE's term
   (§4 table: "`!T` (lent on)"). WELCOME should gloss it once: "lending
   a view you hold passes it on: the same loan, no new one".
7. **Rust migrants need a single bridge sentence, not the word
   everywhere.** WELCOME:63 "Rust calls all three a 'borrow'" becomes
   "Rust uses one word for all three"; WELCOME:261's comparison row
   `| borrow | &x, &mut x | ...` becomes `| lend | ...`. CORE keeps the
   only sentence that names Rust's word (§L exception).
8. **"callable view" is new.** `?fun(Int)` was "a borrowed callable"
   (SPEC:4142, SYNTAX:409). "A callable view" is the receiver-side value,
   consistent with "a view of a function" (CORE §4 last row). Glossed in
   SYNTAX's type table.

## §V3. Documenter (consistency and voice across the docs)

Question: consistency and voice across README, WELCOME, SYNTAX, SPEC,
FAQ, docs/*.md.

Findings.

1. **Two docs state a policy step 7 reverses.** DESIGN.md:282-284
   "Rig keeps *borrow* only as the everyday synonym" and CORE.md:62-65
   "SPEC's *borrow* means a lend or the view it makes. *(Error messages
   still say "borrow" ...)*". Both must be rewritten in the same change
   that renames the diagnostics; CORE keeps only its first sentence
   (§L).
2. **"view" has an old second meaning in SPEC.** SPEC:3034-3035 calls a
   struct field that holds a borrow "a **view**" (struct-holding-a-borrow).
   CORE §1 already absorbs that: a struct whose parts include a view
   *is* a view. So the text survives with "view" meaning the value; drop
   the bold definition and say "a struct holding a view is itself a
   view (CORE §1)".
3. **Headings and anchors** (all links must move with them):
   | Old heading | New heading | Anchor links to fix |
   |---|---|---|
   | SPEC:2712 `### Borrows` | `### Lending` | `#borrows`: SPEC:4009, SYNTAX:399 |
   | SPEC:2902 `#### Write borrows` | `#### Write views` | `#write-borrows`: SPEC:471, :719, :1631 |
   | SPEC:3031 `#### Second-class borrows` | `#### Second-class views` | `#second-class-borrows`: SPEC:2765, :3812, :4150, docs/STD.md:115 |
   | README:41 `### Borrowing` | `### Lending` | none |
   | WELCOME:103 `### Structs, methods, and borrows` | `### Structs, methods, and lending` | none |
   | DESIGN:286 `### Borrows without lifetimes` | `### Views without lifetimes` | none |
   | CORE:584 `**Borrow places.**` | `**View places.**` | none |
4. **Sigil tables say the act for the expression and the view for the
   type.** README:188-189, AGENTS.md:17-18, SPEC:2488-2489, :673-674,
   DESIGN:133-136, SYNTAX:399-400, :1329: `?x` "lend to read", `!x`
   "lend to write", `?T` "read view", `!T` "write view". README's
   "`?T` read-borrowed" becomes "`?T` read view".
5. **Voice.** The owner is the subject of *lend* ("`v` lends", "`?v`
   lends `v` to read"); the holder is the subject of *view* ("`r` views
   `v`", "`r` holds a view of `v`"); *loan* is a thing that is live, is
   carried, lasts, ends. Passive "`x` is lent" only for the owner's
   state. This is the voice CORE and DESIGN:263-279 already use.
6. **SPEC (228 occurrences) is rewritten again in step 8.** Step 7
   still must clear it (the lint), so SPEC gets a rule-driven pass, not
   a prose polish: apply §M2 phrase by phrase, fix headings and error
   blocks, and leave restructuring to step 8.
7. **Counts by doc** (occurrences): SPEC 228, INTERNALS 111, DESIGN 52,
   SYNTAX 26, CORE 16, README 12, WELCOME 11, AGENTS 6, HANDOFF 5,
   FAQ 3, STD 3, examples/README 3, ROADMAP 1 (total 477, of which 46
   are in ```` ```error ```` blocks that follow the diagnostic table).
8. **AGENTS.md and CORE.md are "fixed" documents** (brief-common:
   North Star and CORE are fixed). Their edits here are vocabulary only,
   anticipated by CORE:64-65 itself, but should be confirmed with the
   Rig session (§Q1).

## §V4. Compiler (strings and identifiers in src/*.zig)

Question: every diagnostic, hint and note string, and every internal
identifier containing borrow; a new name for each, consistent across
files, without collisions.

Findings.

1. **Census of src/*.zig and rig.grammar by token** (a tokenizer, not
   a line grep, so a line with an identifier and a comment counts each):
   identifiers 675, doc comments 373, line comments 196, diagnostic
   string literals 168 occurrences in 132 literals, unit-test names 18,
   unit-test expectations 10, emitted-Zig strings 2, generated
   (parser.zig) 12 strings (regenerated, not edited). Total 1,454,
   rig.grammar's 8 included.
2. **68 distinct identifiers** (66 hand-written, 2 generated). The full
   table with per-file counts is §M6.
3. **The internal "borrow" is narrower than CORE's "view".** sema's
   `Borrows.any` / `holdsBorrow` mean *holds a `?T`, `!T`, or slice*,
   and exclude `String`, which is tracked separately as `Borrows.view`
   (src/sema.zig:2047-2061, 3286-3335). CORE §1 lists `String` as a
   view too. So `holdsBorrow` cannot become `holdsView`: the type rules
   accept `Box[String]` and `Cell[String]` (probe: `b = Box("hi")` runs)
   but reject `Box[?Int]` with "`Box[T]` owns its value, so `T` holds
   no borrow" (resolve.zig:2134). The rename needs a name for "a view
   whose type marks it (`?T`, `!T`, `[]T`, `![]T`)", as opposed to a
   String. Recommended internal term: **marked view** (`holdsMarkedView`,
   `Views.marked`), and the existing `Borrows.view` bit (which means
   "holds a String") becomes `Views.string`. User-facing text says
   "view (a String aside)" where the distinction matters (§M3).
4. **Collisions found and resolved:**
   - typecheck `Access` already has `.lend_write` (`!p.f` of a held
     `!T`, i.e. *lending on*) next to `.write_borrow` (`!p`). Rename
     `.write_borrow` → `.lend_write` and the old `.lend_write` →
     `.lend_on`, in one commit.
   - emit already has `emitLend` (lends a callable, emit.zig:5148), so
     `emitBorrowOf` becomes `emitLendAddress`, not `emitLend`.
   - sema `Facts.views` (sema.zig:606, the read-view fact set) would
     share its name with the renamed `TypeInfo.borrows` → `views`.
     Different structs, so it compiles; for grep, rename the fact set to
     `read_views` (collateral, 3 uses).
   - typecheck `isBorrow` (typecheck.zig:8192) duplicates
     `sema.isBorrowType` (sema.zig:3048): delete it and call
     `sema.isReadOrWriteView` (12 uses).
   - `emit.peelBorrows` (emit.zig:5369) is a one-line wrapper of
     `sema.unwrapBorrows`; renamed `peelViews` (or deleted, optional).
   - No proposed name collides with an existing identifier (checked
     each against src/*.zig; the only hits were the ones above and
     comment words).
5. **Generated and mirrored files.** `rig.grammar`'s node names
   `borrow_read`/`borrow_write` (rig.grammar:362, 565, 566) feed
   `src/parser.zig` (14 occurrences: tags, accessors `ir.BorrowRead`,
   `ir.BorrowWrite`) and the IR snapshots (test/ir/*.sexp, 14
   occurrences, regenerated with `./test/run --update ir`).
   `rig.grammar`, `src/rig.zig` (2 diagnostics, 2 identifiers, 3
   comments) and `src/diag.zig` (none) are mirrored in Nexus's
   `test/rig`: a Nexus re-sync is needed.
6. **Runtime names appear in emitted Zig.** `rig.ReadBorrow(T)` and
   `rig.borrowed(T, x)` (runtime.zig:88, 106; written by emit.zig:5224,
   3174) become `rig.ReadView(T)` and `rig.viewed(T, x)`. Emit output
   changes; behavior does not. `rig.lend` already exists and stays.
7. **Verb slots.** Two templates build "cannot {verb} ..." from
   `Access.verb()` (typecheck.zig:980-989, 1201-1205). "lend to write"
   splits around the object; the verb becomes a head/tail pair (§M4).
8. **Unit tests** (ownership.zig:4585-4843, typecheck.zig:9030,
   runtime.zig:2089) carry 18 names and 10 expected strings; they
   change with the diagnostics, in the same commit (§M5).

## §V5. Language designer (coverage of lend / view / loan)

Question: do the three words cover every case, and the compounds?

| Case | Old wording (example) | New wording | Covered by |
|---|---|---|---|
| plain lend | `?x` "read borrow", "borrows `x`" | `?x` lends `x` to read; a **read lend** | CORE §2 s.4 |
| write lend | "write-borrow `v`" | lend `v` to write; a **write lend** | CORE s.4 |
| unwritten read lend | "the read borrow may be left implicit" (SPEC:794) | "the read lend may go unwritten" | CORE s.4 |
| re-lend of a held view | "a call reborrows it" (SPEC:474), "`as` over a write borrow lends it on" | **lends it on**; "a lend of a view lends on the same loan" | CORE §4 rows "a held `!T`", "`![]T`" ("lent on") |
| slice `?x[a..b]` | "a read-only view that borrows `xs`" (SPEC:361) | "a lend of part of `xs`"; the slice is a **view** of its elements | CORE §4 "A slice `x[a..b]` is the same lend, of part of `x`" |
| view of a temporary | "a borrow of the temporary `T` outlives its statement" | "a **view of the temporary** `T` outlives its statement" | CORE §3 "A view of a temporary may be used only within its statement" |
| view stored in a field | "a struct holding a borrow keeps the borrowed value borrowed" | "a struct holding a view is a view; the loan lasts while it is used" | CORE §1 kinds, s.6 |
| closure capture `\|?x\|` / `\|!x\|` | "`?x` borrows `x` for the closure's life" (CORE:605) | "`\|?x\|` lends `x` to the closure, to read, for the closure's life; `\|!x\|` lends it to write"; the closure holds a **captured view** | CORE §7 (text changes) |
| borrowed parameter | "cannot drop borrowed parameter `p`" | "**view parameter** `p`" in diagnostics; "a `?T` parameter" in prose | §M2 |
| returned borrow | "returned borrow of `x` does not originate from a borrowed parameter" | "cannot return a view of `x`, which this function was not lent" | CORE s.7 |
| borrow checker | INTERNALS:37 "Rust's borrow checker", AGENTS "Move / borrow / drop checking" | Rig's: **ownership checker**; Rust's: "Rust's checker" | §M2 |
| `borrowed` (adjective) on the owner | "while `p` is borrowed", "a place borrowed from it" | **lent** ("while `p` is lent", "a place it is lending") | §M1 rule 4 |
| `borrowed` (adjective) on the value | "a borrowed value", "borrowed callable", "borrowed slot", "borrowed handle" | a **view**, **callable view**, "a view of each slot", "the viewed handle" | §M1 rule 4 |
| the record | "while a read borrow is live", "while borrows are live" | "while a **read loan** is live", "while a **loan** is live" | CORE table |
| the aliasing rule | "any number of read borrows or one write borrow" | "any number of read loans, or one write loan" | CORE s.5 |
| `?fun(...)` type | "borrowed callable" | **callable view** | CORE §4 last row |
| types that hold `?T`/`!T`/slices, String aside | "holds no borrow" | user text: "holds no view (a String aside)"; internal: **marked view** | §V4.3 |
| dangling | "dangling borrows" (AGENTS:48, FAQ:19, WELCOME:68) | "dangling views" | §M2 |
| sigils | "borrow sigils", "borrow modes" (SPEC:5046) | "lend sigils" (`?`, `!`), "view types" | §M2 |

Findings.

1. **Every case maps** with one of: lend (act), view (value), loan
   (record), plus the sanctioned compounds and the two adjectives
   *lent* (owner state) and *viewed* (what a view reaches).
2. **Three gaps need an agreed term** (all adopted in §M1): *lend on*
   (CORE's own), *callable view* (new; the `?fun` type), *marked view*
   (internal only).
3. **Compounds** (fixed forms, §M1 rule 3): *read lend / write lend*
   (acts, nouns), *lend to read / lend to write* (verb phrases),
   *read view / write view* (values), *read loan / write loan*
   (records). Never hyphenated verbs (`write-lend`, `read-lend`), which
   the lint also rejects.
4. **HANDOFF's model sentence works as the template for the whole
   conflict family:** `cannot lend `v` to write while a read loan is
   live` (act on the left, record on the right, one name, no "borrow").
5. **One designed exception.** CORE keeps the sentence that names
   Rust's word, so a Rust reader can map it once. Everything else,
   including DESIGN's rationale and WELCOME's bridge, says "Rust uses
   one word for all three" without spelling the word.

---

## §M. The merged guide

### §M1. Term rules (apply to every new string, steps 1-8)

1. **Three words, one meaning each.**
   - **lend** (verb, owner side) / **a lend** (noun, the act or the
     `?x`/`!x` expression). The subject is the owner or the programmer
     acting for it: "`?v` lends `v` to read", "lend it as `?f`".
   - **view** (noun, the value handed over; any `?T`, `!T`, `[]T`,
     `![]T`, `String`, `?fun(...)`, or a value holding one). Verb form
     "views" for the holder: "`r` views `v`".
   - **loan** (noun only, the owner-side record). Never a verb. A loan
     *is live*, *is carried*, *lasts*, *ends*.
2. **Prepositions.** "a view of `x`", "a loan of `x`" (CORE: "the loans
   of everything it was lent"), "lend `x` to read", "lent to write
   here". Not "a loan on `x`".
3. **Fixed compounds:** read lend, write lend; lend to read, lend to
   write; read view, write view; read loan, write loan; lend on (a held
   view, passed on with the same loan: "lends `w` on", "lend on the
   write view held here"); callable view; view parameter (diagnostics
   only). Forbidden: write-lend, read-lend (as verbs), re-lend,
   reborrow, loaned, loaning.
4. **The old adjective `borrowed` splits by what it describes:**
   - the owner, under a loan → **lent**: "while `p` is lent", "`x`
     goes out of scope while it is still lent";
   - the value received → **view** (noun) or **viewed** (what a view
     reaches): "a view", "the viewed handle", "a view of each slot".
   Decide by asking "does this thing own the value?" Yes → lent. No →
   view.
5. **"borrow" as a noun splits three ways by meaning.** Ask which side
   it is on:
   - the act / the expression `?x`, `!x` → **lend**;
   - the value someone holds (a `?T` binding, a field, a parameter, a
     result) → **view**;
   - the record that blocks the owner ("is live", "while borrows are
     ...") → **loan**.
   Test: replace with "the `?x` expression", "the value of type `?T`",
   "the record"; the one that keeps the sentence true is the word.
6. **The String distinction.** Where the sentence is true of every view
   (CORE's sense), say "view". Where it is true only of `?T`, `!T`,
   slices (the old `holdsBorrow`), say "view (a String aside)" or name
   the forms. Internally that class is a **marked view**.
7. **Rust.** Rust's term appears only in CORE's note (§L). Elsewhere:
   "Rust's `&` / `&mut`", "Rust's checker", "Rust uses one word for all
   three".
8. **Checker names.** Rig's checker is "the ownership checker" (src/ownership.zig:3848
   already says "the ownership checker"). "borrow
   checking" in AGENTS:148 becomes "loan checking".

### §M2. Phrase replacement table

Old → new, with the meaning test and an example. Counts are
case-insensitive phrase hits in docs + tests (`git grep -o -i -h`),
from the census; they size the work, not the rule.

| Old phrase | New phrase | Meaning | Example (old → new) |
|---|---|---|---|
| `X` borrows `x` (receiver subject) | `X` views `x` / holds a view of `x` | value | "`r` still borrows it" → "`r` still views it" |
| `?x` borrows `x` / `?x` borrows | `?x` lends `x` (to read) | act | README:7 "`?x` borrows" → "`?x` lends" |
| borrow `x` (imperative) | lend `x` | act | "Borrow it instead: `?b`" → "Lend it instead: `?b`" |
| read-borrow `x` | lend `x` to read | act | "cannot read-borrow `n`" → "cannot lend `n` to read" |
| write-borrow `x` (144 hits) | lend `x` to write | act | "cannot write-borrow `v`" → "cannot lend `v` to write" |
| write-borrows / write-borrowing call | lends ... to write / a call that lends its receiver to write | act | SPEC:834 "write-borrowing call" → "a call that lends its receiver to write" |
| a read borrow `?x` (expression) | a read lend `?x` | act | SPEC:2488 table "read borrow" → "lend to read" |
| a read borrow (value, `?T`) (52 hits "read borrow is" etc.) | a read view | value | "`x` as a read borrow of the value (`?T`)" → "a read view of the value" |
| a write borrow (value, `!T`) | a write view | value | "it holds a write borrow" → "it holds a write view" |
| `!` is a write borrow | `!` lends to write | act | SPEC:1948 → "`!` lends to write; use `not` for negation" |
| a borrow of `x` (value) (76 hits "borrow of") | a view of `x` | value | "store a borrow of `x`" → "store a view of `x`" |
| a borrow of the temporary | a view of the temporary | value | CORE:413 |
| while a read/write borrow is live | while a read/write loan is live | record | CORE:57 |
| while borrows are live | while a loan is live | record | "cannot drop `b` while borrows are live" → "... while a loan is live" |
| while it is read-/write-borrowed | while a read/write loan is live | record | "cannot move `rc` while it is read-borrowed" → "... while a read loan is live" |
| second write borrow on `x` | lend `x` to write while a write loan is live | act + record | ownership.zig:715 |
| `x` is borrowed (owner) | `x` is lent | owner state | "while `p` is borrowed" → "while `p` is lent" |
| `x` is borrowed (x is a view) | `x` is a view (of `y`) | value | "it is borrowed from `r`" → "it is a view of `r`" |
| still borrowed | still lent | owner state | ownership.zig:789 |
| place borrowed from it | place it is lending | owner | ownership.zig:707 |
| borrowed parameter (18 + 8 hits) | view parameter (diagnostics); a `?T` / `!T` parameter (prose) | value | "cannot drop borrowed parameter `rc`" → "cannot drop view parameter `rc`" |
| borrowed value / operand / optional / slot / handle | view / a view operand / a view of an optional / a view of each slot / the viewed handle | value | SPEC:3593 "a borrowed slot" → "a view of the slot" |
| borrowed callable (15 + 10 hits) | callable view | value | "a borrowed callable `?fun()`" → "a callable view `?fun()`" |
| holds a borrow / holds no borrow (25 hits) | holds a view / holds no view; "(a String aside)" where only marked views count | value | resolve.zig:2134 |
| keeps no borrow of it | keeps no view of it | value | typecheck.zig:7031 |
| what it borrows | what it views | value | "match what it borrows" → "match what it views" |
| reborrow(s) / a borrow of a borrow | lend(s) on; a lend of a view lends on the same loan | act | SPEC:474 "a call reborrows it" → "a call lends it on" |
| loop-borrow alias | loop view | value | ownership.zig:2230 |
| captured borrow / captured write borrow | captured view / captured write view | value | ownership.zig:2235, 2360 |
| unique borrow | a write view, which is unique | value | ownership.zig:2373 |
| through a borrow (path) | through a view | value | typecheck.zig:8292 |
| reached through a borrow of the box | reached by lending the box | act | typecheck.zig:1854 |
| explicit read borrow | explicit lend | act | typecheck.zig:1753 |
| borrow forms | lend forms (`?`, `!`) | act | typecheck.zig:6904 |
| borrow sigils / borrow modes | lend sigils / view types | act / type | SPEC:5046 |
| borrowed (array view tag) | lent | act | `ArrayView.borrowed` |
| second-class borrows | second-class views | value | SPEC:3031 |
| dangling borrow(s) | dangling view(s) | value | AGENTS:48 |
| borrow checker (Rig) | ownership checker | — | AGENTS:148 "Move / borrow / drop checking" → "Move / loan / drop checking" |
| borrow checker (Rust) | Rust's checker | — | INTERNALS:37 |
| borrows are never counted | views are never counted | value | DESIGN:239 |
| `?T` read-borrowed / `!T` write-borrowed (type tables) | `?T` read view / `!T` write view | type | README:188-189 |
| takes its receiver write-borrowed | takes its receiver as a write view | value | resolve.zig:1499 |
| requires a write-borrowed receiver | needs its receiver lent to write | act | typecheck.zig:6877-6889 |
| a write-borrowed place | a place lent to write | act | typecheck.zig:4874-4899 |
| Borrowing (heading) | Lending | act | README:41 |

### §M3. Diagnostic rewrite table

Every diagnostic, hint, and note literal in src/*.zig that contains
"borrow" (132 literals, 168 occurrences), old → new. `{s}` slots are
kept. **Bold** marks the test-matched substring that changes most often;
update the `# error:` lines, ```` ```error ```` blocks, and unit-test
expectations by the same mapping (§M5).

**src/ownership.zig** (54 literals)

- 350 `loop_borrow_rule`: "a `for x in ?vec` element is a read borrow of the Vec slot and cannot be cloned, moved, dropped, or stored" → "a `for x in ?vec` element is a read view of the Vec slot and cannot be cloned, moved, dropped, or stored"
- 547: "`{s}` cannot use `{s} = {s}`: a generic function is checked for a `{s}` that holds no borrow; take `?{s}` or `!{s}` in its signature instead" → "... checked for a `{s}` that holds no view (a String aside); take `?{s}` or `!{s}` in its signature instead"
- 571: "... the methods of `{s}` are checked for a `{s}` that holds no borrow" → "... that holds no view (a String aside)"
- 589: "... stores a `{s}` in a Cell, a Signal, or an owned closure, which holds no borrow, and a String may view a Text" → "... which carries no loan, and a String may view a Text"
- 686 note: "`{s}` is borrowed here, and the place is found up to each index before the index runs" → "`{s}` is lent here, and the place is found up to each index before the index runs"
- 689 note: "{s} borrow taken here" → "lent to {s} here"
- 707 `in_index`: "in an index of a place borrowed from it" → "in an index of a place it is lending"
- 710: "cannot read-borrow `{s}`, which holds a Cell, " ++ earlier → "cannot lend `{s}`, which holds a Cell, to read " ++ earlier
- 712: "cannot read-borrow `{s}` while a write borrow is live" → **"cannot lend `{s}` to read while a write loan is live"**
- 713: "cannot write-borrow `{s}` " ++ in_index / ++ earlier → "cannot lend `{s}` to write " ++ ...
- 714: "cannot write-borrow `{s}` while a read borrow is live" → **"cannot lend `{s}` to write while a read loan is live"**
- 715: "cannot take a second write borrow on `{s}`" → **"cannot lend `{s}` to write while a write loan is live"**
- 722: "cannot {s} `{s}` while it is {s}-borrowed" → **"cannot {s} `{s}` while a {s} loan is live"**
- 785 note: "`{s}` goes out of scope while `{s}` still borrows it" → "`{s}` goes out of scope while `{s}` still views it"
- 789 note: "`{s}` goes out of scope while still borrowed" → "`{s}` goes out of scope while it is still lent"
- 802: "a borrow of the temporary `{s}` outlives its statement, which drops it; bind the value to a name first" → **"a view of the temporary `{s}` outlives its statement**, which drops it; bind the value to a name first"
- 1710: "use of `{s}` while a write borrow is live" → **"use of `{s}` while a write loan is live"**
- 1913: "closure `{s}` cannot be write-borrowed; lend it as `?{s}`" → "closure `{s}` cannot be lent to write; lend it as `?{s}`"
- 2136: "cannot move-capture borrowed parameter `{s}`; the caller still owns it. Capture a clone with `|+{s}|`" → "cannot move-capture view parameter `{s}`; the caller still owns what it views. Capture a clone with `|+{s}|`"
- 2137: "... Capture the borrow with `|{s}{s}|`" → "cannot move-capture view parameter `{s}`; the caller still owns what it views. Capture the view with `|{s}{s}|`"
- 2171: "cannot move out of `{s}`: it is borrowed from `{s}`" → "cannot move out of `{s}`: it is a view of `{s}`"
- 2201: "cannot move out of `{s}`: `{s}` is borrowed; exchange it instead: `replace(!{s}, v)`" → "cannot move out of `{s}`: `{s}` is a view; exchange it instead: `replace(!{s}, v)`"
- 2230: "cannot {s} loop-borrow alias `{s}`; " ++ rule → "cannot {s} loop view `{s}`; " ++ rule
- 2235: "cannot {s} captured borrow `{s}`; the closure holds it for every call. Use it through the borrow, or pass it to a call" → "cannot {s} captured view `{s}`; the closure holds it for every call. Use it through the view, or pass it to a call"
- 2272: "cannot {s} `{s}`: it holds a write borrow, which cannot be duplicated" → "cannot {s} `{s}`: it holds a write view, which cannot be duplicated"
- 2308: "cannot drop borrowed parameter `{s}`; the caller owns it" → "cannot drop view parameter `{s}`; the caller owns what it views"
- 2325: "cannot drop `{s}` while borrows are live" → **"cannot drop `{s}` while a loan is live"**
- 2353: "bare use of loop-borrow alias `{s}` in {s} would smuggle the borrowed handle past the loop; " ++ rule → "bare use of loop view `{s}` in {s} would carry the viewed handle past the loop; " ++ rule
- 2360: "bare use of captured write borrow `{s}` in {s} would hand the unique borrow out of the closure environment, again at each call; use it inside the closure instead" → "bare use of captured write view `{s}` in {s} would hand the write view, which is unique, out of the closure environment, again at each call; use it inside the closure instead"
- 2373: "bare use of write borrow `{s}` in {s} would duplicate a unique borrow; use `<{s}` to move it" → "bare use of write view `{s}` in {s} would copy a write view, which is unique; use `<{s}` to move it"
- 2375: "bare use of `{s}` in {s} would duplicate the write borrow it holds; use `<{s}` to move it" → "... would copy the write view it holds; use `<{s}` to move it"
- 2388: "bare use of `{s}` in {s} would duplicate a write borrow; a field cannot be moved out of its parent" → "... would copy a write view; a field cannot be moved out of its parent"
- 2517: "... Borrow it instead: `?{s}` or `!{s}`" → "... Lend it instead: `?{s}` or `!{s}`"
- 2522: "... Borrow it (`?{s}`) or copy the text (`+{s}`)" → "... Lend it (`?{s}`) or copy the text (`+{s}`)"
- 2629: "cannot reassign `{s}` while borrows are live" → **"cannot reassign `{s}` while a loan is live"**
- 2658: "cannot store a borrow of `{s}` through `{s}`: `{s}` borrows `{s}`, which outlives it" → "cannot store a view of `{s}` through `{s}`: `{s}` views `{s}`, which outlives it"
- 2659: "cannot store a borrow of `{s}` through `{s}`: what `{s}` borrows outlives it" → "cannot store a view of `{s}` through `{s}`: what `{s}` views outlives it"
- 2696: "cannot store a borrow of `{s}` through `{s}`: `{s}` outlives it" → "cannot store a view of `{s}` through `{s}`: `{s}` outlives it"
- 2716: "cannot assign to `{s}` while `{s}` is borrowed" → "cannot assign to `{s}` while `{s}` is lent"
- 2725: "cannot store a borrow of `{s}` in a `Cell`: every handle to it could reach the borrow; a value stored in a Cell or Signal may not hold one" → "cannot store a view of `{s}` in a `Cell`: every handle to it could reach the view; a value stored in a Cell or Signal carries no loan"
- 2743: "cannot store a borrow of `{s}` in `{s}`: `{s}` borrows `{s}`, which outlives it" → "cannot store a view of `{s}` in `{s}`: `{s}` views `{s}`, which outlives it"
- 2746: "cannot store a borrow of `{s}` in `{s}`: `{s}` outlives it" → "cannot store a view of `{s}` in `{s}`: `{s}` outlives it"
- 2781: "cannot store a borrow of `{s}` through captured `{s}`: ..." → "cannot store a view of `{s}` through captured `{s}`: ..." (rest unchanged)
- 2905: as 2725, "in a `{s}`" → "cannot store a view of `{s}` in a `{s}`: every handle to it could reach the view; a value stored in a Cell or Signal carries no loan"
- 3062: "cannot take a second write borrow on `{s}`: to swap two elements of `{s}`, write `!{s}.swap({s}, {s})`" → "cannot lend `{s}` to write while a write loan is live: to swap two elements of `{s}`, write `!{s}.swap({s}, {s})`"
- 3237: "cannot store a borrow of `{s}` through `{s}`: `{s}` outlives it" → "cannot store a view of `{s}` through `{s}`: `{s}` outlives it"
- 3238: "cannot let this call store a borrow of `{s}` in `{s}`: `{s}` outlives it" → "cannot let this call store a view of `{s}` in `{s}`: `{s}` outlives it"
- 3302: "an owned closure cannot borrow `{s}`: it can be stored anywhere, so it could outlive `{s}`; ..." → "an owned closure cannot capture a view of `{s}`: it can be stored anywhere, so it could outlive `{s}`; ..."
- 3306: "an owned closure cannot capture `{s}`, which holds a borrow{s}{s}{s}; ..." → "an owned closure cannot capture `{s}`, which holds a view{s}{s}{s}; ..."
- 3380: "cannot capture closure `{s}`; closures cannot be copied. Borrow it with `|?{s}|`" → "cannot capture closure `{s}`; closures cannot be copied. Lend it with `|?{s}|`"
- 3388: "cannot capture `{s}` while a write borrow is live" → "cannot capture `{s}` while a write loan is live"
- 3455: "cannot return a borrow of `{s}`: a parameter taken by value belongs to this function and ends with it; take `{s}: ?{s}` to return a borrow of the caller's value" → "cannot return a view of `{s}`: a parameter taken by value belongs to this function and ends with it; take `{s}: ?{s}` to return a view of the caller's value"
- 3458: "returned borrow of `{s}` does not originate from a borrowed parameter" → **"cannot return a view of `{s}`, which this function was not lent"**
- 4131: "`{s}` is dropped before `{s}`, whose `drop` body could still read it through this borrow" → "... through this view"

**src/typecheck.zig** (70 literals)

- 795: "a borrowed callable `{s}` lives only as long as what it borrows, so it cannot be a module-level binding" → "a callable view `{s}` lives only as long as what it views, so it cannot be a module-level binding"
- 911 note: "`{s} = v` writes the `{s}` that `{s}` borrows; `{s} = !m` points `{s}` at another place" → "`{s} = v` writes the `{s}` that `{s}` views; `{s} = !m` points `{s}` at another place"
- 983 verb: "write-borrow" → verb pair `.{ "lend", " to write" }` (§M4)
- 1151: "cannot {s} the write borrow held here through a shared handle (`*T`); other handles reach the same write borrow" → "cannot {s} the write view held here: it is reached through a shared handle (`*T`), and other handles reach the same write view"
- 1152: "cannot {s} the write borrow held here through a read borrow (`?T`); other borrows may reach the same write borrow" → "cannot {s} the write view held here: it is reached through a read view (`?T`), and other views may reach the same write view"
- 1153: "cannot {s} the write borrow held here through {s}" → "cannot {s} the write view held here: it is reached through {s}" (fills unchanged: "a slice (`[]T`), which is read-only", ...)
- 1169: "cannot {s} through a read borrow (`?T`); take a write borrow (`!T`) to mutate" → "cannot {s} through a read view (`?T`); take a write view (`!T`) to mutate" (with the verb pair: "cannot lend to write through a read view ...", "cannot assign through a read view ...")
- 1181: "cannot write-borrow a temporary: the change would be lost; bind it to a name first" → "cannot lend a temporary to write: the change would be lost; bind it to a name first"
- 1202 verb: "write-borrow" → verb pair `.{ "lend", " to write" }` (§M4)
- 1396: "the loop step cannot use `{s}`: it is a borrow (`{s}`) that lives only in the body; ..." → "the loop step cannot use `{s}`: it is a view (`{s}`) that lives only in the body; ..."
- 1492 and 3222 op fragment: "moves out of a borrow a value" → "moves out of a view a value" (reads "the generic body moves out of a view a value that holds a `T`")
- 1495: "`as` over a write borrow lends it on: write `!{s}` to borrow the value inside" → "`as` over a write view lends it on, visibly: write `!{s}` to bind a write view of the value inside"
- 1607: "the loop would walk a borrow of the temporary `{s}` after its header drops it; ..." → "the loop would walk a view of the temporary `{s}` after its header drops it; ..."
- 1753: "resource Vec[T] iteration requires an explicit read borrow; write `for x in ?vec`" → "a loop over a Vec of resources needs an explicit lend; write `for x in ?vec`"
- 1765: "`<{s}` would move the elements out of a Vec that `{s}` only borrows; ..." → "... a Vec that `{s}` only views; ..."
- 1775: "each element of `{s}` is a write borrow, which a loop binding cannot hold; ..." → "each element of `{s}` is a write view, which a loop binding cannot hold; ..."
- 1780: "each element holds a write borrow, which a loop binding would copy; ..." → "each element holds a write view, which a loop binding would copy; ..."
- 1840: "`match <{s}` consumes an owned value, and `{s}` is a write borrow (`{s}`); ..." → "... and `{s}` is a write view (`{s}`); ..."
- 1841: "... and `{s}` is a borrow (`{s}`); match what it borrows with `match {s}`" → "... and `{s}` is a view (`{s}`); match what it views with `match {s}`"
- 1854: "a `match` reaches the value inside a box through a borrow: `match ?{s}` or `match !{s}`; to take the value out, bind it first: ..." → "a `match` reaches the value inside a box by lending the box: `match ?{s}` or `match !{s}`; to take the value out, bind it first: ..."
- 1857: same head → "a `match` reaches the value inside a box by lending the box: `match ?{s}`"
- 2246: "cannot bind `{s}`: it holds a write borrow, and the matched value is reached through a read borrow or shared handle, which cannot write" → "cannot bind `{s}`: it holds a write view, and the matched value is reached through a read view or shared handle, which cannot write"
- 2461 (and resolve.zig:309): "... `|?{s}|` or `|!{s}|` borrows it, ..." → "... `|?{s}|` or `|!{s}|` lends it, ..."
- 3236: "a borrow cannot give up the resource inside it; borrow the value inside with `if {s}{s} as {s}`" → "a view cannot give up the resource inside it; lend the value inside with `if {s}{s} as {s}`"
- 3288: "cannot borrow an element of a Cell's Vec: the cell may change while the borrow lives; ..." → "cannot lend an element of a Cell's Vec: the cell may change while the view lives; ..."
- 3300: "`!` is a write borrow; use `not` for negation (a `Bool` is write-borrowed only where a `!Bool` is expected: `f(!flag)`)" → **"`!` lends to write; use `not` for negation** (a `Bool` is lent to write only where a `!Bool` is expected: `f(!flag)`)"
- 3305: "cannot write-borrow a `{s}`: its elements are read-only; ..." → "cannot lend a `{s}` to write: its elements are read-only; ..."
- 3309: "cannot write-borrow through a read borrow `{s}`" → "cannot lend to write through a read view `{s}`"
- 3322: "cannot borrow this: it holds a Cell, and `{s}` is a loop or match binding, a copy, so changes through the borrow would be lost" → "cannot lend this: it holds a Cell, and `{s}` is a loop or match binding, a copy, so changes through the view would be lost"
- 3326: "cannot borrow a temporary that holds a Cell: a change through the borrow would have no place; ..." → "cannot lend a temporary that holds a Cell: a change through the view would have no place; ..."
- 3388: "cannot write-borrow a slice of a String; a String is read-only" → "cannot lend a slice of a String to write; a String is read-only"
- 3392: "cannot write-borrow a slice of a Text; a Text changes only through its methods (...)" → "cannot lend a slice of a Text to write; a Text changes only through its methods (...)"
- 3397: "cannot write-borrow a slice of a `{s}`; a `[]T` is read-only (...)" → "cannot lend a slice of a `{s}` to write; a `[]T` is read-only (...)"
- 3469: "a handle holds a value, not a borrow; `{s}` is a borrow: share an owned value instead" → "a handle holds a value, not a view; `{s}` is a view: share an owned value instead"
- 3508: "`+x` cannot clone a `{s}`: it is a write borrow of elements it does not own; ..." → "`+x` cannot clone a `{s}`: it is a write view of elements it does not own; ..."
- 4171 (and resolve.zig:966): "a handle holds a value, not a borrow: `{s}` has no handle" → "a handle holds a value, not a view: `{s}` has no handle"
- 4441: "a slice of a `![]T` borrows it; write `?{s}` or `!{s}`" → "a slice of a `![]T` is a lend of it; write `?{s}` or `!{s}`"
- 4453: "a slice of a Text borrows it; write `?{s}`" → "a slice of a Text is a lend of it; write `?{s}`"
- 4464: "a slice of an array or Vec borrows it; write `?{s}`" → "a slice of an array or Vec is a lend of it; write `?{s}`"
- 4581: "... `{s}` holds a borrow, and its element must be plain data" → "... `{s}` holds a view, and its element must be plain data"
- 4874: "`replace` takes a write-borrowed place and the value to put there: `replace(!x, v)`" → "`replace` takes a place lent to write and the value to put there: `replace(!x, v)`"
- 4882: "`swap` takes two write-borrowed places: `swap(!a, !b)`" → "`swap` takes two places lent to write: `swap(!a, !b)`"
- 4899: "`{s}` takes a write-borrowed place: `!x`; got `{s}`" → "`{s}` takes a place lent to write: `!x`; got `{s}`"
- 4903: "`{s}` moves values that hold no borrow; `{s}` may hold one" → "`{s}` moves values that hold no view; `{s}` may hold one" (add "(a String aside)" only if the predicate there is `mayHoldBorrow`, which excludes String: check at edit time)
- 5708: "`{s}` cannot take a borrowed callable for `{s}`: ..." → "`{s}` cannot take a callable view for `{s}`: ..."
- 6231: "...; to borrow the call's result, write `?({s}.{s}(...))`" → "...; to lend the call's result, write `?({s}.{s}(...))`"
- 6429: "... `{s}` holds a borrow, and the elements must be plain data" → "... `{s}` holds a view, and the elements must be plain data"
- 6827: "... drop the `?`, or borrow the call's result with `?({s}.{s}(...))`" → "... drop the `?`, or lend the call's result with `?({s}.{s}(...))`"
- 6845 hint: "; to borrow the call's result, write `?({s}.{s}(...))`" → "; to lend the call's result, write `?({s}.{s}(...))`"
- 6854: "a write-borrowing call that returns `Bool` is written `(!{s}).{s}(...)`, so it is never read as negation" → "a call that lends its receiver to write and returns `Bool` is written `(!{s}).{s}(...)`, so it is never read as negation"
- 6874: "method `{s}` takes a read borrow of receiver; cannot move" → "method `{s}` takes its receiver as a read view; cannot move"
- 6877: "method `{s}` requires a write-borrowed receiver; cannot upgrade a read borrow to a write borrow" → "method `{s}` needs its receiver lent to write; a read view cannot become a write view"
- 6882: "method `{s}` requires a write-borrowed receiver; this expression yields a borrowed value, not an owned one" → "method `{s}` needs its receiver lent to write; this expression yields a view, not an owned value"
- 6884: "method `{s}` requires a write-borrowed receiver; got `?...`; use `!receiver.{s}(...)`" → "method `{s}` needs its receiver lent to write; got `?...`; use `!receiver.{s}(...)`"
- 6885: "method `{s}` requires a write-borrowed receiver; cannot move; ..." → "method `{s}` needs its receiver lent to write; cannot move; ..."
- 6889: "method `{s}` requires a write-borrowed receiver; use `!receiver.{s}(...)`" → **"method `{s}` needs its receiver lent to write**; use `!receiver.{s}(...)`"
- 6898: "method `{s}` consumes the receiver; cannot consume through a borrowed value" → "method `{s}` consumes the receiver; cannot consume through a view"
- 6904: "method `{s}` consumes the receiver; borrow forms not allowed; use `<receiver.{s}(...)`" → "method `{s}` consumes the receiver; a lend cannot give it up; use `<receiver.{s}(...)`"
- 6963: "...; only a number, `Bool`, `String`, or plain enum is copied out of a borrow: take the borrow where it goes (`?{s}` or `!{s}`)" → "...; only a number, `Bool`, `String`, or plain enum is copied out of a view: lend it on where it goes (`?{s}` or `!{s}`)"
- 7031: "a temporary array is lent as a `{s}` only to a call that keeps no borrow of it; ..." → "... only to a call that keeps no view of it; ..."
- 7107: "...: `?{s}` reads `{s}` for the call; write `?({s})` to borrow the call's result" → "...; write `?({s})` to lend the call's result"
- 7116: "type mismatch: expected `{s}`, got `{s}`; lend a {s} borrow: `{c}{s}`" → "type mismatch: expected `{s}`, got `{s}`; lend it to {s}: `{c}{s}`" (fill "read"/"write" unchanged)
- 7223: "`{s}` borrows a closure for the call; write the closure without `*` (drop the `*`)" → "`{s}` views a closure for the call; write the closure without `*` (drop the `*`)"
- 8022: "cannot write-borrow through a read borrow `{s}`; capture it with `|?{s}|`" → "cannot lend to write through a read view `{s}`; capture it with `|?{s}|`"
- 8027: "cannot write-borrow a `{s}`: its elements are read-only; capture it with `|?{s}|`" → "cannot lend a `{s}` to write: its elements are read-only; capture it with `|?{s}|`"
- 8040: "... so changes through the borrow would be lost" → "... so changes through the view would be lost"
- 8292 `cell_place`: "... or one reached through a borrow (`?T` or `!T`) or a shared handle (`*T`). ..." → "... or one reached through a view (`?T` or `!T`) or a shared handle (`*T`). ..."
- 8914: "field `{s}` holds a borrow" → "field `{s}` holds a view (`?T`, `!T`, or a slice)" (the `==` reason; a String field compares, so name the forms)
- 8922: "`{s}` is a borrow" → "`{s}` is a view"

**src/resolve.zig** (5)

- 309: as typecheck.zig:2461 ("`|?{s}|` or `|!{s}|` lends it")
- 664: "slices cannot view values that own resources (`{s}`); borrow the Vec instead" → "slices cannot view values that own resources (`{s}`); lend the Vec instead"
- 966: as typecheck.zig:4171
- 1499: "`drop` takes its receiver write-borrowed: `drop(!self)`" → "`drop` takes its receiver as a write view: `drop(!self)`"
- 2134: "`Box[T]` owns its value, so `T` holds no borrow; got `{s}`" → "`Box[T]` owns its value, so `T` holds no view (a String aside); got `{s}`"

**src/rig.zig** (2; mirrored in Nexus)

- 435: "... or `x = !y` for a write borrow" → "... or `x = !y` to lend `y` to write"
- 1484: "Rig borrows with `?x` (read) or `!x` (write)" → "Rig lends with `?x` (to read) or `!x` (to write)"

**src/sema.zig** (1)

- 2797 `held_callable`: "a borrowed callable `{s}` is only a parameter's, a local's, or a result's type; no value can hold one" → "a callable view `{s}` is only a parameter's, a local's, or a result's type; no value can hold one"

### §M4. Composed messages (the verb slot)

`Access.verb()` (typecheck.zig:980-989) and `requireBinding`'s `verb`
(typecheck.zig:1201-1205) put one word in "cannot {verb} <object>".
"lend ... to write" wraps the object, so the verb becomes a pair:

```zig
const Verb = struct { head: []const u8, tail: []const u8 = "" };
// .lend_write (old .write_borrow), .set_cell  -> .{ .head = "lend", .tail = " to write" }
// .lend_on (old .lend_write), .pass_write      -> .{ .head = "lend on" }
// .write_through                               -> .{ .head = "write through" }
// .assign -> "assign to", .write_iterate -> "write-iterate", .take -> "take"
```

Templates become "cannot {head} <object>{tail}<rest>"; where no object
is named, "cannot {head}{tail} through ...". Resulting strings (test
substrings in bold):

- 1213, 1238: "cannot lend constant `{s}` to write" (**cannot write-borrow constant** ×4)
- 1224: "cannot lend parameter `self` to write; parameters are immutable (take `!self` to write through to the caller)"
- 1225: "cannot lend parameter `{s}` to write; parameters are immutable (bind a copy with `new {s} = {s}`, or take `{s}: !{s}` ...)" (**cannot write-borrow parameter** ×6)
- 1230: "cannot lend captured `{s}` to write; captures are fixed when the closure is created"
- 1239: "cannot lend fixed binding `{s}` to write (bound with `=!`)" (**cannot write-borrow fixed** ×5)
- 1247, 1258-1260: "cannot lend `{s}` to write: `match {s}` reads `{s}` ...", "... : it is a copy of an element of `{s}` ...", etc.
- 1265-1266: "cannot lend `{s}` to write; loop and pattern bindings are immutable (...)"
- 1165: "cannot lend to write through a shared handle (`*T`); other handles may exist. ..."
- 1166: "cannot lend to write through a slice; a `[]T` is read-only"
- 1167: "cannot lend a byte of a String to write; a String is read-only"
- 1168: "cannot lend `.len` to write; a length is read-only"
- 1151-1153 with `.lend_on`: "cannot lend on the write view held here: it is reached through a read view (`?T`), ..."; with `.write_through`: "cannot write through the write view held here: it is reached through a read view (`?T`), ..." (old "cannot write through the write borrow held here through a read borrow" read "through ... through")

### §M5. Unit tests, test expectations, doc error blocks

- Unit-test **expectations** (ownership.zig:4602, 4724, 4738, 4747,
  4767, 4775, 4785, 4843) follow §M3: e.g. 4747 → "cannot return a view
  of `user`, which this function was not lent"; 4767 → "cannot move
  `rc` while a read loan is live"; 4775 → "cannot drop view parameter
  `rc`".
- Unit-test **names** (18 occurrences): rename by §M1, e.g.
  ownership.zig:4585 "temporary read borrow ends at statement end" →
  "temporary read lend's loan ends at statement end"; 4595 "bound
  borrow blocks write" → "bound view blocks write"; 4699 "borrow may
  not outlive an inner scope" → "view may not outlive an inner scope";
  4712 "borrow chosen by if keeps both roots borrowed" → "view chosen
  by if keeps both roots lent"; 4727 "borrow returned from a call
  borrows the argument" → "view returned from a call views the
  argument"; 4741 "returned borrow of a local is rejected" → "returned
  view of a local is rejected"; 4750 "returned borrow of a borrowed
  parameter is fine" → "returned view of a view parameter is fine";
  4761 "method receiver is borrowed for the whole call" → "method
  receiver is lent for the whole call"; 4770 "dropping a borrowed
  parameter is rejected" → "dropping a view parameter is rejected";
  4778 "move-capturing a borrowed parameter ..." → "move-capturing a
  view parameter ..."; 4831 "a borrowed parameter may store borrows the
  caller passed in" → "a view parameter may store views the caller
  passed in"; typecheck.zig:9030 "check: reborrow of a borrowed
  parameter" → "check: lending on a view parameter"; runtime.zig:2089
  "a borrowed callable calls ..." → "a callable view calls ...".
- **`# error:` lines** (test/reject 517 occurrences in 416 lines;
  test/corpus 12) and **```` ```error ```` blocks** (46: SPEC 34,
  CORE 10, WELCOME 2) change in the same commit as §M3. They are
  substrings, so update each to the substring of the new message. The
  normalized expectation census (top 10): "cannot write-borrow `_`
  while a read borrow is live" 39, "a borrow of the temporary `_`
  outlives its statement" 38, "cannot drop `_` while borrows are live"
  23, "use of `_` while a write borrow is live" 17, "cannot store a
  borrow of `_` in a `_`" 15, "returned borrow of `_` does not
  originate from a borrowed parameter" 14, "cannot take a second write
  borrow on `_`" 14, "cannot reassign `_` while borrows are live" 14,
  "cannot write-borrow `_` while an earlier argument's read of it is in
  use" 8, "`_` is a write borrow; use `_` for negation" 8.

### §M6. Identifier rename table

Every identifier containing "borrow" (any case) in src/*.zig and
rig.grammar, with its uses per file (tokenizer census; generated
`parser.zig` uses follow the grammar). New names were checked against
every identifier in src/ for collisions (§V4.4).

| Old | New | Uses | Where (count) | Meaning / note |
|---|---|---|---|---|
| `borrow_write` | `write_view` | 112 | typecheck.zig 62, sema.zig 18, ownership.zig 12, emit.zig 9, resolve.zig 8, rig.grammar 2, rig.zig 1 | IR node and TypeData tag for `!T`; `ir.BorrowWrite` → `ir.WriteView` |
| `borrow_read` | `read_view` | 97 | typecheck.zig 46, sema.zig 18, emit.zig 13, resolve.zig 9, ownership.zig 8, rig.grammar 2, rig.zig 1 | IR node and TypeData tag for `?T` (grammar `→ (borrow_read)`); `ir.BorrowRead` → `ir.ReadView` |
| `unwrapBorrows` | `unwrapViews` | 57 | typecheck.zig 48, ownership.zig 4, sema.zig 4, emit.zig 1 | sema: peel `?T`/`!T` (doc comment says so; not slices or String) |
| `peelBorrows` | `peelViews` | 34 | emit.zig 34 | emit wrapper over `sema.unwrapBorrows`; optional: delete and call `sema.unwrapViews` |
| `borrowed` | by declaration, see below | 31 | typecheck.zig 20, ownership.zig 8, emit.zig 1, runtime.zig 1, sema.zig 1 | 31 uses, 7 declarations |
| `borrows` | `views` | 26 | sema.zig 26 | sema `TypeInfo`/`Reach` field of type `Borrows` |
| `mayCarryBorrow` | `mayCarryLoan` | 24 | ownership.zig 24 | ownership wrapper over `sema.mayHoldView`: whether the checker tracks loans the value carries |
| `borrow` | by declaration, see below | 19 | emit.zig 11, runtime.zig 3, sema.zig 3, typecheck.zig 2 | 19 uses, 5 declarations |
| `isPtrBorrowTy` | `isPtrViewTy` | 16 | emit.zig 16 | emit: a view held as a pointer |
| `emitBorrowValue` | `emitWriteViewPtr` | 13 | emit.zig 13 | emit: "the pointer a `!T` expression denotes" |
| `write_borrow` | `Access.write_borrow`→`.lend_write` (and the old `.lend_write`→`.lend_on`); `ReceiverTypeKind.write_borrow`→`.write_view` | 12 | typecheck.zig 12 | typecheck: 6 Access uses (971, 983, 3317, 3412, 6557, 8038), 6 ReceiverTypeKind uses (4968, 6881, 6888, 6898, 8230, 8252) |
| `isBorrow` | (delete; use `sema.isReadOrWriteView`) | 12 | typecheck.zig 12 | typecheck.zig:8192 duplicates `sema.isBorrowType` |
| `isPtrBorrowExpr` | `isPtrViewExpr` | 11 | emit.zig 11 | emit |
| `read_borrow` | `Block.read_borrow`→`.read_view`; `ReceiverTypeKind.read_borrow`→`.read_view` | 10 | typecheck.zig 10 | typecheck: Block 1024, 1030, 1101, 1152, 1169; ReceiverTypeKind 4967, 6877, 6898, 8230, 8251 |
| `loop_borrow` | `loop_view` | 9 | ownership.zig 9 | ownership `Var` field: a `for x in ?vec` element |
| `unborrowed` | `stripLend` | 8 | emit.zig 8 | emit.zig:5835: `e` without the `?`/`!` sigils |
| `holdsBorrow` | `holdsMarkedView` | 8 | typecheck.zig 4, ownership.zig 2, resolve.zig 1, sema.zig 1 | sema: holds a `?T`, `!T`, or slice (a String aside) |
| `carriesWriteBorrow` | `carriesWriteView` | 7 | ownership.zig 7 | ownership |
| `unborrowedNode` | `stripSigil` | 7 | typecheck.zig 7 | typecheck.zig:8158: strips `?`, `!`, and `<` |
| `genericReadBorrow` | `genericReadView` | 6 | emit.zig 6 | emit |
| `through_borrow` | `through_view` | 6 | ownership.zig 6 | ownership `Place` field |
| `walkBorrowedPath` | `walkViewedPath` | 6 | ownership.zig 6 | ownership |
| `holdsWriteBorrow` | `holdsWriteView` | 6 | typecheck.zig 4, ownership.zig 1, sema.zig 1 | sema |
| `is_borrow` | `is_lend` (emit.zig:1247) / `is_write_view` (ownership.zig:3208) | 5 | emit.zig 3, ownership.zig 2 | two unrelated locals |
| `reborrow` | `lendOn` (ownership fn) / `lends_on` (emit local) | 5 | ownership.zig 3, emit.zig 2 | CORE §4 "lent on" |
| `borrowVar` | `lendVar` | 5 | ownership.zig 5 | ownership |
| `rejectBorrowedView` | `rejectTakenView` | 5 | ownership.zig 5 | ownership: rejects moving/dropping a var that is a view |
| `ReadBorrow` | `ReadView` | 5 | runtime.zig 5 | runtime type fn; emitted as `rig.ReadBorrow(` (emit.zig:5224) |
| `emitBorrowOf` | `emitLendAddress` | 4 | emit.zig 4 | emit: `?x`/`!x` held by pointer (`emitLend` already exists, for callables) |
| `writeBorrowedOpen` | `writeViewedOpen` | 4 | emit.zig 4 | emit; writes `rig.viewed(` |
| `genericReadBorrowOf` | `genericReadViewOf` | 4 | emit.zig 4 | emit |
| `ret_may_borrow` | `ret_may_view` | 4 | ownership.zig 4 | ownership `Func` field |
| `isBorrowed` | `isLent` | 4 | ownership.zig 4 | ownership: a var has a live loan |
| `borrowedRoot` | `viewedRoot` | 4 | ownership.zig 4 | ownership: the root a write-view var views |
| `isBorrowType` | `isReadOrWriteView` | 4 | resolve.zig 2, sema.zig 1, typecheck.zig 1 | sema: `?T` or `!T` |
| `Borrows` | `Views` | 4 | sema.zig 4 | sema packed struct; fields `any`→`marked`, `view`→`string`, `write`, `text` stay |
| `BorrowKind` | `LendKind` | 4 | typecheck.zig 4 | typecheck enum { read, write } |
| `borrowsOptionalValue` | `viewsOptionalValue` | 3 | emit.zig 3 | emit |
| `readBorrowIsPtr` | `readViewIsPtr` | 3 | emit.zig 3 | emit |
| `readBorrowCopies` | `readViewCopies` | 3 | emit.zig 1, sema.zig 1, typecheck.zig 1 | sema |
| `BorrowQuery` | `LoanQuery` | 3 | ownership.zig 3 | ownership: the query `findLoan` takes |
| `loop_borrow_rule` | `loop_view_rule` | 3 | ownership.zig 3 | ownership const message fragment |
| `holdsBorrowType` | `holdsMarkedViewType` | 3 | ownership.zig 3 | ownership wrapper over `sema.holdsBorrow` |
| `walkBorrow` | `walkLend` | 3 | ownership.zig 3 | ownership |
| `sexpMentionsBorrow` | `sexpMentionsView` | 3 | ownership.zig 3 | ownership: mentions `read_view`/`write_view` |
| `handleOfBorrow` | `handleOfView` | 3 | resolve.zig 3 | resolve |
| `copiedBorrow` | `copiedByReadView` | 3 | runtime.zig 3 | runtime, mirrors `sema.copiedByBorrow` |
| `borrows_only` | `views_only` | 3 | sema.zig 3 | sema `Reach` const |
| `copiedByBorrow` | `copiedByReadView` | 3 | sema.zig 3 | sema |
| `mayHoldBorrow` | `mayHoldMarkedView` | 3 | typecheck.zig 2, sema.zig 1 | sema |
| `borrowSlice` | `lendSlice` | 3 | typecheck.zig 3 | typecheck |
| `synthBorrow` | `synthLend` | 3 | typecheck.zig 3 | typecheck: types `?x`/`!x` |
| `borrowGivesUp` | `viewGivesUp` | 3 | typecheck.zig 3 | typecheck: reports a view giving up its resource |
| `storesBorrow` | `storesView` | 3 | typecheck.zig 3 | typecheck |
| `binds_borrow` | `binds_view` | 2 | emit.zig 2 | emit local |
| `bindOptionalBorrow` | `bindOptionalView` | 2 | emit.zig 2 | emit |
| `writeCapturedBorrow` | `writeCapturedView` | 2 | emit.zig 2 | emit |
| `outer_borrows` | `outer_is_view` | 2 | emit.zig 2 | emit local |
| `returnMayBorrow` | `returnMayView` | 2 | ownership.zig 2 | ownership |
| `walkRejectedBorrow` | `walkRejectedLend` | 2 | ownership.zig 2 | ownership |
| `isWriteBorrowPlace` | `isWriteViewPlace` | 2 | ownership.zig 2 | ownership |
| `root_borrows` | `root_is_write_view` | 2 | ownership.zig 2 | ownership local |
| `handsOverWriteBorrow` | `handsOverWriteView` | 2 | typecheck.zig 2 | typecheck |
| `moves_borrow` | `moves_write_view` | 2 | typecheck.zig 2 | typecheck local |
| `rejectWriteBorrowBindings` | `rejectWriteViewBindings` | 2 | typecheck.zig 2 | typecheck |
| `captureBorrow` | `captureLend` | 2 | typecheck.zig 2 | typecheck: `|?x|`/`|!x|` |
| `BorrowRead` | `ReadView` | 1 | parser.zig 1 | generated accessor (parser.zig) — follows the grammar |
| `BorrowWrite` | `WriteView` | 1 | parser.zig 1 | generated accessor (parser.zig) — follows the grammar |

**Per-declaration renames for the short names:**

- `borrowed` (31 uses):
  - `sema.ArrayView.borrowed` (sema.zig:669; uses emit.zig:3281,
    ownership.zig:1941, typecheck.zig:7011, 7016, 7063) → `.lent`
  - `ownership.Via.borrowed` (ownership.zig:172; uses 2170, 3577,
    3582, 3703) → `.viewed`
  - ownership local (ownership.zig:758, 761) → `lent`
  - `typecheck.Root.borrowed` (typecheck.zig:1011; uses 1117, 1118,
    1289) → `.view`
  - typecheck locals "is the type `?T`/`!T`" (1486, 1487, 1505, 3098,
    3099, 3221, 3222) → `through_view`
  - typecheck `synthSlice` parameter (4425, 4429, 4440, 4452, 4456,
    4463) → `lent`
  - runtime `pub fn borrowed` (runtime.zig:106) → `viewed`, emitted as
    `rig.viewed(` (emit.zig:3174)
- `borrow` (19 uses):
  - `sema` reason enum tag `.borrow` (sema.zig:2896; uses 2967, 2968,
    typecheck.zig:8914, 8922) → `.view`
  - `emit.AssignValue.borrow` (emit.zig:1422; uses 1394, 1448) → `.view`
  - `emit.emitBorrowOf` parameter `borrow` (emit.zig:3156-3165, 7
    uses) → `lend`
  - runtime `borrowed`'s parameter `borrow` (runtime.zig:106-107, 3
    uses) → `view`
- `borrows` (26, sema.zig) is the `Borrows` field of `TypeInfo` and
  `Reach` → `views`; the struct's fields `any` → `marked`, `view` →
  `string` (`write`, `text` unchanged).
- Collateral (no "borrow" in the name, renamed to keep meanings
  distinct): typecheck `Access.lend_write` → `.lend_on` (6 uses);
  sema `Facts.views` → `read_views` (3 uses); optionally
  `sema.holdsViewOnly` → `holdsStringOnly` (4) since `Views.view` is
  now `Views.string`.

### §M7. Grammar, IR, runtime

- rig.grammar:362, 565, 566: node names `borrow_read` → `read_view`,
  `borrow_write` → `write_view`; regenerate (`zig build parser`), which
  renames the tags and accessors `ir.BorrowRead`/`ir.BorrowWrite` →
  `ir.ReadView`/`ir.WriteView` in src/parser.zig.
- rig.grammar:560-561 comment "A borrow applies to the whole type after
  it ... `?User?` borrows an optional User" → "A view sigil applies to
  the whole type after it ... `?User?` is a read view of an optional
  User"; rig.grammar:773 "|?x| read borrow   |!x| write borrow" →
  "|?x| lend to read   |!x| lend to write".
- IR snapshots test/ir/{control_flow,expressions,sigils,types}.{raw,sem}.sexp
  (14 occurrences): `./test/run --update ir`; INTERNALS:342's sample
  `(borrow_read Packet)` → `(read_view Packet)`.
- Nexus mirror: rig.grammar and src/rig.zig change, so re-sync Nexus's
  `test/rig` copies byte-for-byte in the same change.
- Runtime: `ReadBorrow` → `ReadView`, `borrowed` → `viewed`,
  `copiedBorrow` → `copiedByReadView`; `lend` stays. INTERNALS:1142,
  1208, 1296 name them.

### §M8. Doc-term rules (for the documents)

1. Apply §M1-§M2 by meaning. Every doc example's ```` ```error ````
   block follows §M3.
2. Headings and anchors per §V3.3; fix every link in the same commit.
3. Sigil tables: expression column "lend to read" / "lend to write";
   type column "read view" / "write view"; `?fun(...)` "callable view".
4. Per document:
   - **CORE.md** (16): five error blocks; replace :62-65 with the one
     sentence the lint allows: "*Borrow*, the word Rust uses, names the
     same event from the receiver's side; Rig names everything from the
     side the sigil is on." (drop "SPEC's *borrow* means ..." and the
     "Error messages still say ..." note); :584 "Borrow places." →
     "View places."; :605-606 "`?x` borrows `x` for the closure's life,
     `!x` borrows it to write" → "`?x` lends `x` to the closure for its
     life, to read, `!x` lends it to write".
   - **DESIGN.md** (52): :259-261 "Rust calls this idea a *borrow*" →
     "Rust uses one word for this idea, and it ends up meaning three
     things: the act (`&v`), the reference that act makes, and the
     checker's record of it"; replace :282-284 ("Rig keeps *borrow* only
     as the everyday synonym ...") with "The full rules are in
     [CORE](CORE.md)."; :286 heading; the language table
     :510-517 ("the shared-or-exclusive borrow rule" → "the
     shared-or-exclusive rule", "second-class borrows" → "second-class
     references" (Swift's own term), "borrows as parameter conventions"
     → "views as parameter conventions"); :505 "It borrows specific
     ideas" → "It takes specific ideas" (English "borrow" counts too).
   - **WELCOME.md** (11): :63 → "Rust uses one word for all three.";
     :261 row label → "lend"; :58-59 adds that a view may write (§V2.2);
     :501, :533 error blocks per §M3.
   - **AGENTS.md** (6): sigil table rows → "lend to read / read view",
     "lend to write / write view"; :48 "dangling views"; :79 "a fresh
     owned value, a lend, or a view"; :85 "never silently forgets a
     loan"; :148 "Move / loan / drop checking".
   - **README.md** (12), **SYNTAX.md** (26), **FAQ.md** (3),
     **STD.md** (3), **ROADMAP.md** (1), **examples/README.md** (3):
     phrase table only.
   - **SPEC.md** (228): rule-driven pass (§V3.6); headings per §V3.3.
   - **INTERNALS.md** (111): rule-driven; IR sample per §M7; the
     "Borrows" emit bullet (:1133) → "Views"; the `Borrows` bits
     (:971-983) → `Views` with `marked`/`string` per §M6.
   - **HANDOFF.md** (5): reword step 7 and the vocabulary note without
     the word ("the Rust word", "the old word"), or delete HANDOFF when
     the revamp ends; it gets no lint exception.
5. Test-file comments (test/reject 361, test/behavior 225,
   test/corpus 43, examples/*.rig 7): §M1-§M2 by meaning. Rig code
   identifiers: test/reject/ownership/coalesce_jump_checks_rest.rig:17,
   :40 `fun borrowed(k: Int)` → `fun lent(k: Int)`; test/matrix.py:90,
   :193 context id `borrow_arg` → `lend_arg` (matrix ids change; `-k`
   filters with the old id stop matching).

### §M9. Test file paths

305 tracked paths contain "borrow" (test/reject 143, test/corpus 83,
test/behavior 79). Nothing references them by name (`git grep` for
`borrow*.rig` finds nothing). Rename by meaning with `git mv` in a
rename-only commit (no content change, so `git log --follow` keeps
history), using these defaults, then review each name:

| Token | Default | When it means something else |
|---|---|---|
| `write_borrow` (20+) | `write_view` | the act → `lend_write` (e.g. `write_borrow_temporary` → `lend_write_temporary`) |
| `read_borrow`, `readborrow` | `read_view` | the act → `lend_read` |
| `borrow` (63) | `view` | the record → `loan` (e.g. `borrow_ends_at_last_use` → `loan_ends_at_last_use`); the act → `lend` (e.g. `borrow_of_temporary_escapes` → `view_of_temporary_escapes`) |
| `borrowed` | `lent` (owner) / `view` (value) | `borrowed_param` → `view_param`; `borrowed_callable` → `callable_view` |
| `borrows` | `views` / `lends` | `as_borrows_*` → `as_lends_*` |
| `reborrow` | `lend_on` | |

The corpus sample (`CORPUS_SAMPLE=16`, test/run:541) is picked by a
hash of each name, so renaming 83 corpus files changes which probes the
default run samples; `./test/run corpus` still runs them all.

---

## §L. The lint

**What fails.** A new check in `./test/run` (kind `vocab`, also run by
default):

1. `git grep -n -I -i --untracked -e 'borr[o]w'` over the tree (tracked
   and untracked-but-not-ignored files), case-insensitive substring: it
   catches `borrow`, `Borrow`, `borrowed`, `reborrow`, `unborrowed`,
   `borrow_read`, `ReadBorrow`, `write-borrow`. The pattern is written
   `borr[o]w` so the lint's own source never matches itself.
2. `git ls-files --cached --others --exclude-standard | grep -i 'borr[o]w'`:
   any path containing the word.
3. Secondary patterns (same report), for the forms §M1 rule 3 forbids:
   `\b(read|write)-l(end|ends|ent|ending)\b` (hyphenated verbs; the rule
   is "lend to write"), `\bre-?lend`, and `\bloan(ed|ing)\b`. "loans"
   used as a verb ("`v` loans ...") is not detectable mechanically;
   review catches it.

Each hit prints `file:line: stray "borrow": <line>` and a pointer to
docs/CORE.md "Three words"; any hit fails the run.

**Allowed exceptions** (an exact list in the lint, by file and full
line text, not by line number):

| File | Line text | Why |
|---|---|---|
| docs/CORE.md | `*Borrow*, the word Rust uses, names the same event from the receiver's` | CORE's note, the only sanctioned use (HANDOFF step 7) |

The lint also fails when an allowed entry no longer matches exactly one
line (a stale exception), so the list cannot silently grow or rot.
Nothing else is exempt: not src/parser.zig (it is regenerated clean),
not test/corpus (its comments and paths are renamed too), not HANDOFF.md.
(.git/revamp lives under .git, outside the work tree, so the grep never
sees it.)

**Where it runs.** `./test/run` (so CI and every commit), and fast
enough for a pre-commit habit: two `git grep`s over the tree, well under
a second.

**When it lands.** In the last commit of step 7, once the tree is
clean; landing it first would make every intermediate commit red.

---

## §C. Counts

Census (worktree `rig-revamp` at `38fc9265`):

| Measure | Count |
|---|---|
| `git grep -n -i borrow` lines | **2,619** |
| occurrences (`git grep -o -i`) | **3,115** |
| files with content hits | **473** |
| tracked paths containing the word | **305** |
| distinct identifiers | **68** (66 hand-written, 2 generated) |
| diagnostic literals containing it | **132** (168 occurrences) |

**By category** (occurrences):

| Category | Occurrences | Where |
|---|---|---|
| Identifiers (src, grammar) | 675 | §M6 |
| Doc comments `///` (src) | 373 | ownership 154, sema 78, emit 65, typecheck 65, runtime 7, resolve 3, rig 1 |
| Line comments `//` (src) + grammar comments | 192 + 4 | ownership 76, typecheck 63, emit 45, resolve 2, rig 2, runtime 2, sema 2; grammar 4 |
| Diagnostic strings (src) | 168 | typecheck 91, ownership 69, resolve 5, rig 2, sema 1 |
| Unit-test names / expectations | 18 / 10 | ownership 15+10, typecheck 2, runtime 1 |
| Emitted-Zig strings | 2 | emit.zig:3174, 5224 |
| Generated parser.zig strings | 12 | regenerated (its 2 identifier hits are counted above) |
| Test expectations `# error:` | 529 | test/reject 517, test/corpus 12 |
| Doc ```` ```error ```` blocks | 46 | SPEC 34, CORE 10, WELCOME 2 |
| Test comments | 629 | test/reject 361, test/behavior 225, test/corpus 43 |
| Test code | 19 | test/ir sexp 14, matrix.py 2, reject `fun borrowed` 2, behavior 1 (trailing comment) |
| Example programs (comments) | 7 | examples/*.rig |
| Doc prose (md, minus error blocks) | 431 | §V3.7 |
| Paths | 305 | test/reject 143, test/corpus 83, test/behavior 79 |

**By file, source and docs** (occurrences / lines):

| File | Occ. | Lines |
|---|---|---|
| src/typecheck.zig | 476 | 389 |
| src/ownership.zig | 461 | 396 |
| src/emit.zig | 267 | 225 |
| src/sema.zig | 166 | 131 |
| src/resolve.zig | 33 | 28 |
| src/runtime.zig | 22 | 18 |
| src/parser.zig (generated) | 14 | 12 |
| src/rig.zig | 7 | 6 |
| rig.grammar | 8 | 6 |
| SPEC.md | 228 | 199 |
| docs/INTERNALS.md | 111 | 89 |
| docs/DESIGN.md | 52 | 46 |
| SYNTAX.md | 26 | 25 |
| docs/CORE.md | 16 | 12 |
| README.md | 12 | 8 |
| WELCOME.md | 11 | 11 |
| AGENTS.md | 6 | 6 |
| HANDOFF.md | 5 | 5 |
| FAQ.md | 3 | 3 |
| docs/STD.md | 3 | 3 |
| examples/README.md | 3 | 2 |
| docs/ROADMAP.md | 1 | 1 |

Tests and examples: test/reject 880 occurrences in 260 files,
test/behavior 226 in 143, test/corpus 55 in 35, test/ir 14 in 8,
test/matrix.py 2, examples/*.rig 7 in 5. Per file: Appendix A. Paths:
Appendix B. Totals check: src+grammar 1,454 + tests 1,177 + examples 7
+ docs 477 = 3,115.

---

## §P. Commit plan (each commit keeps `./test/run -j 2` green)

| # | Commit | Size (occ.) | Verify |
|---|---|---|---|
| 1 | Rename the `?T`/`!T` IR nodes to `read_view`/`write_view` (grammar, regenerate parser, every `.borrow_read`/`.borrow_write` use, IR snapshots, INTERNALS sample); Nexus re-sync | ~240 | `test/equiv.py OLD NEW`: only `parse`/`normalize` node names differ |
| 2 | Rename internal identifiers (§M6, minus the grammar ones) and runtime names | ~470 | equiv: zero diffs except `emit` (`rig.ReadView`, `rig.viewed`) and `--facts=sema` tag names |
| 3 | Rewrite diagnostics, unit tests, `# error:` lines, doc error blocks (§M3-§M5) | ~770 | suite + `./test/run -j 2 corpus` (corpus carries 12 expectations); equiv: only `check` text differs |
| 4 | Rewrite src comments and grammar comments | ~570 | equiv: zero diffs |
| 5 | Rewrite test and example comments, Rig identifiers, matrix ids | ~640 | suite, `test/matrix.py -j 2` |
| 6 | Rename test files (`git mv` only) | 305 paths | suite (counts unchanged) |
| 7 | Rewrite docs: CORE, AGENTS, README, WELCOME, FAQ, SYNTAX, STD, ROADMAP, examples/README, HANDOFF | ~75 | doc examples in suite |
| 8 | Rewrite SPEC, INTERNALS, DESIGN | ~355 | doc examples in suite |
| 9 | Add the lint | — | suite green with the lint; a deliberate stray fails it |

Commits 1-2 touch `src/ownership.zig` and typecheck's classification
code by name only, but AGENTS "one branch at a time touches ownership"
still applies: schedule step 7 when no other ownership branch is open.

## §Q. Questions for the Rig session

1. CORE.md and AGENTS.md's North Star table are "fixed"; confirm the
   vocabulary-only edits in §M8.4 (CORE:62-65, :584, :605-606; AGENTS
   sigil table).
2. Confirm "a loan of `x`" over "a loan on `x`" (§M1.2).
3. Confirm the internal term "marked view" and the user phrase "(a
   String aside)" (§V4.3), or choose another name for the
   `?T`/`!T`/slice class.
4. Confirm "callable view" for `?fun(...)` (was "borrowed callable").
5. Confirm renaming the 83 corpus probe files (they are "kept" probes;
   renaming keeps their content).
6. Confirm DESIGN's language table keeps Swift's own term
   ("second-class references") instead of the old "second-class
   borrows".


---

## Appendix A. Occurrences per test and example file

`git grep -o -i borrow` per file, test/ and examples/*.rig (451 files, 1,184 occurrences).

```text
   1  examples/memo_canary.rig
   1  examples/ownership_tour.rig
   2  examples/sort.rig
   3  examples/tree.rig
   1  test/behavior/effects/propagate_none_chains.rig
   1  test/behavior/emit/assign_value_first.rig
   1  test/behavior/emit/borrow_result_operands.rig
   2  test/behavior/emit/borrow_result_values.rig
   1  test/behavior/emit/cell_in_literal_field.rig
   3  test/behavior/emit/clone_borrowed_handle_result.rig
   3  test/behavior/emit/dropped_borrow_binding.rig
   1  test/behavior/emit/generic_read_borrow_instances.rig
   2  test/behavior/emit/generic_read_borrow_of_vec_element.rig
   1  test/behavior/emit/match_on_borrow.rig
   1  test/behavior/emit/match_on_borrow_call.rig
   1  test/behavior/emit/match_subject_evaluated_once.rig
   3  test/behavior/emit/optional_borrow_from_branch.rig
   1  test/behavior/emit/print_reads_cell_places_after_later_args.rig
   1  test/behavior/emit/print_reads_cell_vec_after_later_args.rig
   1  test/behavior/emit/print_reads_struct_cell_after_later_args.rig
   1  test/behavior/emit/read_borrow_large_by_pointer.rig
   2  test/behavior/emit/read_borrow_local_rebind.rig
   2  test/behavior/emit/write_borrow_copy_element.rig
   1  test/behavior/modules/closure_args_across_modules/main.rig
   1  test/behavior/modules/pub_members/main.rig
   1  test/behavior/modules/qualified_imported_members/main.rig
   1  test/behavior/modules/qualified_type_annotations/main.rig
   2  test/behavior/ownership/as_borrows_cell_and_fresh.rig
   2  test/behavior/ownership/as_borrows_optional_value.rig
   2  test/behavior/ownership/as_borrows_through_paths.rig
   1  test/behavior/ownership/borrow_ends_at_last_use.rig
   1  test/behavior/ownership/borrow_ends_with_scope.rig
   3  test/behavior/ownership/borrow_in_local_struct.rig
   2  test/behavior/ownership/borrow_param_field_returned.rig
   2  test/behavior/ownership/borrow_param_returned.rig
   2  test/behavior/ownership/borrow_released_by_drop.rig
   1  test/behavior/ownership/borrow_slice_element_returned.rig
   2  test/behavior/ownership/borrowed_temporary_lives_for_statement.rig
   1  test/behavior/ownership/builtin_result_does_not_borrow_receiver.rig
   1  test/behavior/ownership/capture_write_owned_match_binding.rig
   2  test/behavior/ownership/cell_set_from_borrowed_copy.rig
   1  test/behavior/ownership/clone_borrowed_handle.rig
   3  test/behavior/ownership/closure_capture_borrows.rig
   4  test/behavior/ownership/closure_passes_captured_borrow.rig
   2  test/behavior/ownership/closure_returns_captured_borrow.rig
   2  test/behavior/ownership/closure_write_capture_bindings.rig
   2  test/behavior/ownership/copy_readable_after_last_write.rig
   1  test/behavior/ownership/copy_write_borrow_read_or_moved.rig
   1  test/behavior/ownership/defer_effects_at_continuing_exits.rig
   1  test/behavior/ownership/defer_reads_borrow_of_earlier_local.rig
   2  test/behavior/ownership/drop_body_borrows_older_value.rig
   1  test/behavior/ownership/failing_condition_store_unused_after.rig
   3  test/behavior/ownership/field_store_through_local_write_borrow.rig
   2  test/behavior/ownership/function_field_through_write_self.rig
   3  test/behavior/ownership/loop_value_moves_out.rig
   1  test/behavior/ownership/match_payload_moved_out_of_block.rig
   1  test/behavior/ownership/match_payload_write_borrow.rig
   1  test/behavior/ownership/match_subject_borrow_ends_with_bindings.rig
   1  test/behavior/ownership/match_write_payload.rig
   3  test/behavior/ownership/method_plain_receiver_keeps_no_loan.rig
   1  test/behavior/ownership/method_returns_borrow.rig
   2  test/behavior/ownership/move_write_borrow_into_local.rig
   2  test/behavior/ownership/move_write_borrow_of_copy.rig
   1  test/behavior/ownership/moved_borrow_ends_with_call.rig
   1  test/behavior/ownership/read_borrow_branch_value_keeps_owner.rig
   4  test/behavior/ownership/read_borrow_of_owner_is_not_dropped.rig
   2  test/behavior/ownership/read_borrow_returned_handle.rig
   2  test/behavior/ownership/rebind_local_write_borrow.rig
   2  test/behavior/ownership/rebind_local_write_borrow_by_move.rig
   2  test/behavior/ownership/return_write_borrow.rig
   7  test/behavior/ownership/slice_return_array_param.rig
   3  test/behavior/ownership/store_through_local_write_borrow.rig
   2  test/behavior/ownership/store_through_nested_borrow_field.rig
   2  test/behavior/ownership/string_copies_free.rig
   1  test/behavior/ownership/string_view_iterators.rig
   1  test/behavior/ownership/take_places_more.rig
   1  test/behavior/ownership/temporaries_drop_order.rig
   1  test/behavior/ownership/temporaries_read_then_dropped.rig
   1  test/behavior/ownership/temporary_views_in_statement.rig
   1  test/behavior/ownership/text_view_loans.rig
   1  test/behavior/ownership/vec_for_clone_elem.rig
   1  test/behavior/ownership/vec_push_after_iteration.rig
   2  test/behavior/ownership/write_borrow_arg_plain_pointee.rig
   2  test/behavior/ownership/write_borrow_args_of_several_types.rig
   2  test/behavior/ownership/write_borrow_in_payload.rig
   4  test/behavior/ownership/write_borrow_lent_as_copied_read.rig
   1  test/behavior/ownership/write_borrow_lent_on.rig
   2  test/behavior/ownership/write_borrow_view.rig
   2  test/behavior/ownership/write_borrows_in_sibling_calls.rig
   1  test/behavior/ownership/write_through_borrow_element.rig
   1  test/behavior/ownership/write_through_borrow_field.rig
   2  test/behavior/ownership/write_through_local_borrow.rig
   2  test/behavior/runtime/cell_borrow_sees_updates.rig
   1  test/behavior/runtime/cell_set_through_read_borrow.rig
   1  test/behavior/runtime/closure_args.rig
   3  test/behavior/runtime/closure_captures_write_borrow.rig
   2  test/behavior/runtime/closure_clone_captures_borrowed_handle.rig
   2  test/behavior/runtime/owned_closure_through_borrow.rig
   1  test/behavior/runtime/print_floats_payloads_and_bytes.rig
   1  test/behavior/runtime/reactive_canary.rig
   1  test/behavior/runtime/reactive_cascade.rig
   1  test/behavior/runtime/reactive_int_source.rig
   1  test/behavior/runtime/vec_for_closures.rig
   1  test/behavior/runtime/vec_len_through_borrows.rig
   1  test/behavior/runtime/vec_push_after_loop.rig
   1  test/behavior/syntax/closure_assignment_body.rig
   1  test/behavior/syntax/read_receiver_sigil.rig
   1  test/behavior/syntax/sigil_spacing.rig
   1  test/behavior/syntax/sigils_before_calls.rig
   1  test/behavior/types/borrow_and_string_branches.rig
   2  test/behavior/types/borrow_number_literal.rig
   1  test/behavior/types/borrowed_copy_reads_as_value.rig
   1  test/behavior/types/box_edge_cases.rig
   3  test/behavior/types/box_lent_as_value.rig
   1  test/behavior/types/box_match_enum.rig
   2  test/behavior/types/box_recursive_enum.rig
   1  test/behavior/types/box_search_tree.rig
   1  test/behavior/types/box_vec_elements.rig
   3  test/behavior/types/callable_vs_function_borrows.rig
   1  test/behavior/types/cell_in_temporary_field.rig
   1  test/behavior/types/closure_arg_inference_order.rig
   1  test/behavior/types/compound_assignment_all_operators.rig
   2  test/behavior/types/equality_claims.rig
   1  test/behavior/types/fallible_sub.rig
   1  test/behavior/types/for_write_iteration.rig
   2  test/behavior/types/forward_borrowed_param.rig
   2  test/behavior/types/generic_fn_borrowed_operands.rig
   1  test/behavior/types/index_through_shared_handle.rig
   1  test/behavior/types/method_read_receiver.rig
   1  test/behavior/types/method_write_receiver.rig
   2  test/behavior/types/optional_handle_binding.rig
   1  test/behavior/types/read_borrowed_int.rig
   1  test/behavior/types/read_locals.rig
   2  test/behavior/types/rebind_borrow_local.rig
   1  test/behavior/types/receiver_sigil_bool_value.rig
   1  test/behavior/types/replace_swap_generic.rig
   2  test/behavior/types/showcase_program.rig
   1  test/behavior/types/slice_array.rig
   1  test/behavior/types/slice_behind_pointer.rig
   1  test/behavior/types/slice_copy_into_param.rig
   2  test/behavior/types/text_borrows_as_strings.rig
   1  test/behavior/types/text_views.rig
   1  test/behavior/types/variant_literal_equality.rig
   1  test/behavior/types/write_borrow_bool.rig
   2  test/behavior/types/write_borrow_calls_mutating_method.rig
   1  test/behavior/types/write_slice.rig
   1  test/behavior/types/write_slice_quicksort.rig
   3  test/corpus/R11b-fuzzout1-s22_147/main.rig
   3  test/corpus/R11b-fuzzout1-s23_194/main.rig
   3  test/corpus/R11b-fuzzout1-s23_37/main.rig
   3  test/corpus/R11b-fuzzout1-s24_15/main.rig
   3  test/corpus/R11b-fuzzout1-s24_84/main.rig
   1  test/corpus/R15-repro-copy_into_param.rig
   1  test/corpus/R15-repro-copy_keeps_source_borrowed.rig
   1  test/corpus/audit-fuzz-pf1-accepted-abca6d5a73.rig
   1  test/corpus/audit-fuzz-pf1-accepted-ef0d28d8d2.rig
   1  test/corpus/audit-fuzz-pf2-accepted-03c023f2ea.rig
   1  test/corpus/audit-fuzz-pf2-accepted-09732fa32c.rig
   1  test/corpus/audit-fuzz-pf2-accepted-0bb6dd2b9b.rig
   2  test/corpus/audit-fuzz-pf2-accepted-15fd628194.rig
   2  test/corpus/audit-fuzz-pf2-accepted-44453d184e.rig
   1  test/corpus/audit-fuzz-pf2-accepted-4d8679916a.rig
   1  test/corpus/audit-fuzz-pf2-accepted-7714d23c7f.rig
   1  test/corpus/audit-fuzz-pf2-accepted-9b74455fdb.rig
   1  test/corpus/audit-fuzz-pf2-accepted-c99f9be183.rig
   1  test/corpus/audit-fuzz-pf2-accepted-dd5a12b6ca.rig
   1  test/corpus/audit-fuzz-pf2-accepted-e821af59c0.rig
   2  test/corpus/audit-fuzz-pf2-accepted-f9f37a33c7.rig
   1  test/corpus/box-t_tree.rig
   3  test/corpus/box-tree_example.rig
   1  test/corpus/purity-newbie-bank2.rig
   1  test/corpus/purity-rustzig-stock.rig
   1  test/corpus/review-revamp-checkers-p-a1.rig
   1  test/corpus/review-revamp-rest-mut-a_34-bad1.rig
   1  test/corpus/review-revamp-rest-mut-a_34-bad2.rig
   1  test/corpus/review-revamp-rest-mut-a_41-m.rig
   1  test/corpus/review-revamp-rest-mut-a_42-m.rig
   2  test/corpus/review-revamp-rest-mut-t_11-d1.rig
   4  test/corpus/review-revamp-rest-mut-t_11-m.rig
   2  test/corpus/review-revamp-rest-mut-t_12-d1.rig
   1  test/corpus/review-revamp-rest-mut-t_13-d1.rig
   1  test/corpus/t-b.rig
   2  test/ir/control_flow.raw.sexp
   2  test/ir/control_flow.sem.sexp
   1  test/ir/expressions.raw.sexp
   1  test/ir/expressions.sem.sexp
   2  test/ir/sigils.raw.sexp
   2  test/ir/sigils.sem.sexp
   2  test/ir/types.raw.sexp
   2  test/ir/types.sem.sexp
   2  test/matrix.py
   1  test/reject/modules/cross_borrow_mode/a.rig
   2  test/reject/modules/cross_borrow_mode/main.rig
   3  test/reject/modules/foreign_constant_write/main.rig
   3  test/reject/modules/foreign_instance_ownership/main.rig
   1  test/reject/modules/imported_borrow_stored_through_write_borrow/main.rig
   2  test/reject/modules/imported_constant_write/main.rig
   2  test/reject/modules/imported_write_borrow_holder_copy/main.rig
   1  test/reject/modules/private_members/main.rig
  18  test/reject/ownership/argument_read_then_written.rig
   3  test/reject/ownership/as_bare_write_borrow.rig
   2  test/reject/ownership/as_binding_lent_through_body.rig
   2  test/reject/ownership/as_borrow_aliasing.rig
   7  test/reject/ownership/as_borrow_aliasing_ownership.rig
   1  test/reject/ownership/assign_borrow_to_local_write_borrow.rig
   2  test/reject/ownership/borrow_chain_through_long_loop.rig
   4  test/reject/ownership/borrow_chosen_by_if.rig
   1  test/reject/ownership/borrow_escapes_by_break.rig
   1  test/reject/ownership/borrow_escapes_loop_body.rig
   6  test/reject/ownership/borrow_field_of_call_result.rig
   5  test/reject/ownership/borrow_in_returned_struct.rig
   7  test/reject/ownership/borrow_of_temporary_escapes.rig
   2  test/reject/ownership/borrow_outlives_inner_scope.rig
   4  test/reject/ownership/borrow_result_owning_value.rig
   4  test/reject/ownership/borrow_returned_from_fn.rig
   2  test/reject/ownership/borrow_slice_element_outlives.rig
   3  test/reject/ownership/borrow_stored_by_callee.rig
   3  test/reject/ownership/borrow_stored_in_field.rig
   2  test/reject/ownership/borrow_stored_through_borrowed_param.rig
   3  test/reject/ownership/borrow_stored_through_passed_write_borrow.rig
  12  test/reject/ownership/borrowed_callable_escape.rig
   7  test/reject/ownership/borrowed_callable_results.rig
   4  test/reject/ownership/box_borrows.rig
   4  test/reject/ownership/box_borrows_ownership.rig
   1  test/reject/ownership/box_owns_uniquely_ownership.rig
   2  test/reject/ownership/box_vec_bare_iteration.rig
   3  test/reject/ownership/boxed_text_view.rig
   3  test/reject/ownership/branch_read_cell_changed_later.rig
  11  test/reject/ownership/call_argument_writes_place.rig
   4  test/reject/ownership/callable_call_result_loans.rig
   2  test/reject/ownership/capture_write_borrow_of_copy.rig
   3  test/reject/ownership/cell_set_on_param.rig
   6  test/reject/ownership/cell_store_value_holding_borrow.rig
   2  test/reject/ownership/cell_vec_element_view.rig
   5  test/reject/ownership/clone_of_shared_view_keeps_borrow.rig
   3  test/reject/ownership/clone_write_borrow_holder.rig
   3  test/reject/ownership/closure_capture_borrow_rules.rig
  12  test/reject/ownership/closure_capture_borrow_rules_ownership.rig
   3  test/reject/ownership/closure_holds_borrow.rig
   8  test/reject/ownership/closure_param_stored_through_capture.rig
   2  test/reject/ownership/closure_result_borrows_captured_borrow.rig
   2  test/reject/ownership/closure_returns_local_borrow.rig
   3  test/reject/ownership/closure_tail_borrows_local.rig
   7  test/reject/ownership/coalesce_jump_borrowed_optional.rig
   3  test/reject/ownership/coalesce_jump_checks_rest.rig
   3  test/reject/ownership/copy_field_borrow_keeps_loan.rig
   9  test/reject/ownership/copy_read_while_write_borrow_live.rig
  15  test/reject/ownership/copy_write_borrow_duplicated.rig
   2  test/reject/ownership/defer_ends_loan_at_propagate.rig
   1  test/reject/ownership/defer_reads_borrow_of_later_local.rig
   1  test/reject/ownership/defer_stores_borrow.rig
   1  test/reject/ownership/defer_stores_borrow_at_break.rig
   1  test/reject/ownership/defer_stores_borrow_of_scope_var.rig
   1  test/reject/ownership/defer_stores_borrow_past_propagate.rig
   4  test/reject/ownership/drop_body_reads_borrow_stored_through_moved_write_borrow.rig
   1  test/reject/ownership/drop_body_reads_younger_borrow.rig
   2  test/reject/ownership/drop_borrowed_param.rig
   4  test/reject/ownership/field_store_through_local_write_borrow_outlives.rig
   2  test/reject/ownership/for_consuming_iteration_moves.rig
   4  test/reject/ownership/for_move_borrowed_vec.rig
   2  test/reject/ownership/for_move_element_keeps_borrow.rig
   4  test/reject/ownership/for_temporary_source_loans.rig
   7  test/reject/ownership/for_write_borrow_elements.rig
   3  test/reject/ownership/for_write_iteration_conflicts_ownership.rig
   3  test/reject/ownership/generic_as_borrowed.rig
   2  test/reject/ownership/header_temporary_outlived.rig
   4  test/reject/ownership/header_temporary_view_bound.rig
   6  test/reject/ownership/if_header_view_escapes.rig
   4  test/reject/ownership/if_value_header_view_escapes.rig
  13  test/reject/ownership/index_of_borrowed_place.rig
   1  test/reject/ownership/joined_as_failing_part_stores.rig
   4  test/reject/ownership/lend_held_write_borrow_needs_mutable.rig
   4  test/reject/ownership/loop_element_of_made_array_borrows.rig
   1  test/reject/ownership/loop_value_borrows_loop_local.rig
   7  test/reject/ownership/match_borrow_subject_misuse.rig
   5  test/reject/ownership/match_consume_borrow.rig
   3  test/reject/ownership/match_field_overwrite_while_payload_live.rig
   2  test/reject/ownership/match_field_payload_through_borrow.rig
   2  test/reject/ownership/match_guard_stores.rig
   4  test/reject/ownership/match_payload_write_borrow_twice.rig
   7  test/reject/ownership/match_subject_lent_through_arms.rig
   3  test/reject/ownership/match_subject_reassign_while_binding_live.rig
   4  test/reject/ownership/match_tail_payload_of_borrowed.rig
   2  test/reject/ownership/match_write_binding_excludes.rig
   6  test/reject/ownership/method_receiver_keeps_loan.rig
   2  test/reject/ownership/move_capture_borrowed_param.rig
   2  test/reject/ownership/move_capture_borrowed_param_lambda.rig
   1  test/reject/ownership/move_ends_copy_values.rig
   2  test/reject/ownership/move_field_from_borrowed_param.rig
   1  test/reject/ownership/move_field_from_borrowed_self.rig
   1  test/reject/ownership/move_field_in_drop_body.rig
   2  test/reject/ownership/move_payload_of_borrowed_scrutinee.rig
   1  test/reject/ownership/move_scrutinee_while_payload_live.rig
   9  test/reject/ownership/moved_borrow_keeps_loans_in_call.rig
   3  test/reject/ownership/nll_borrowed_view.rig
   3  test/reject/ownership/nll_captured_later.rig
   3  test/reject/ownership/nll_closure_holds_borrow.rig
   3  test/reject/ownership/nll_deferred_use.rig
   2  test/reject/ownership/nll_drop_reaches_borrow.rig
   1  test/reject/ownership/nll_escapes_by_break.rig
   2  test/reject/ownership/nll_guarded_statement.rig
   3  test/reject/ownership/nll_loop_condition.rig
   3  test/reject/ownership/nll_next_iteration.rig
   1  test/reject/ownership/nll_payload_after_move.rig
   3  test/reject/ownership/nll_reborrow_through_write.rig
   4  test/reject/ownership/nll_returned_borrow_still_used.rig
   3  test/reject/ownership/nll_view_used_later.rig
   6  test/reject/ownership/owned_closure_captures_borrow.rig
   3  test/reject/ownership/propagate_none_owning_binding.rig
   1  test/reject/ownership/read_borrow_after_drop.rig
   1  test/reject/ownership/read_borrow_after_move.rig
   2  test/reject/ownership/read_while_write_borrow_live.rig
   2  test/reject/ownership/receiver_borrow_with_move_arg.rig
   1  test/reject/ownership/receiver_sigil_parenthesized.rig
   1  test/reject/ownership/repoint_local_write_borrow.rig
   3  test/reject/ownership/resource_temp_borrow.rig
   4  test/reject/ownership/return_borrow_chosen_by_if.rig
   4  test/reject/ownership/return_borrow_of_local.rig
   3  test/reject/ownership/return_struct_with_local_borrow.rig
   1  test/reject/ownership/shared_element_write.rig
   2  test/reject/ownership/shared_field_write_borrow.rig
   2  test/reject/ownership/shared_view_pushed_into_vec.rig
   2  test/reject/ownership/signal_subscriber_borrow.rig
   5  test/reject/ownership/slice_copy_same_root.rig
   2  test/reject/ownership/slice_diagnostics.rig
   3  test/reject/ownership/slice_diagnostics_ownership.rig
   2  test/reject/ownership/slice_of_copy_escapes.rig
   3  test/reject/ownership/slice_push_while_live.rig
   8  test/reject/ownership/slice_return_array_copy.rig
   2  test/reject/ownership/slice_return_local.rig
   1  test/reject/ownership/slice_temporary_kept.rig
   2  test/reject/ownership/slice_write_while_live.rig
   5  test/reject/ownership/store_borrow_through_held_write_borrow.rig
   3  test/reject/ownership/store_borrow_through_local_write_borrow.rig
   3  test/reject/ownership/store_through_loop_element_outlives.rig
   5  test/reject/ownership/store_through_nested_borrow_outlives.rig
   3  test/reject/ownership/store_through_write_borrow_outlives.rig
   8  test/reject/ownership/string_borrow_in_cell.rig
   3  test/reject/ownership/string_copies_keep_text.rig
   9  test/reject/ownership/string_view_results.rig
   1  test/reject/ownership/string_view_stores.rig
   2  test/reject/ownership/string_view_untracked.rig
   3  test/reject/ownership/swap_same_collection.rig
   2  test/reject/ownership/take_rejections.rig
   4  test/reject/ownership/take_rejections_ownership.rig
   1  test/reject/ownership/take_through_borrow_of_temporary.rig
   5  test/reject/ownership/temporaries_not_kept.rig
  10  test/reject/ownership/temporary_part_view_kept.rig
   7  test/reject/ownership/temporary_views_kept.rig
   3  test/reject/ownership/text_add_while_viewed.rig
   4  test/reject/ownership/text_drop_while_viewed.rig
   1  test/reject/ownership/text_move_while_viewed.rig
   2  test/reject/ownership/text_string_param_in_cell.rig
   2  test/reject/ownership/text_view_escaping_closure.rig
   4  test/reject/ownership/text_view_returned.rig
   5  test/reject/ownership/text_view_through_write_borrow.rig
   2  test/reject/ownership/vec_for_drop_elem.rig
   1  test/reject/ownership/vec_for_no_borrow.rig
   3  test/reject/ownership/vec_for_write_during_iter.rig
   3  test/reject/ownership/vec_push_during_iteration.rig
   2  test/reject/ownership/while_header_view_one_error.rig
   3  test/reject/ownership/while_step_uses_borrow_binding.rig
   3  test/reject/ownership/write_borrow_copied.rig
   3  test/reject/ownership/write_borrow_copied_by_binding.rig
   2  test/reject/ownership/write_borrow_field_lent_to_struct.rig
   4  test/reject/ownership/write_borrow_holder_passed_bare.rig
   3  test/reject/ownership/write_borrow_in_struct_copied.rig
   3  test/reject/ownership/write_borrow_lent_bare.rig
   8  test/reject/ownership/write_borrow_lent_bare_unwritable.rig
   8  test/reject/ownership/write_borrow_lent_through_read_borrow.rig
   3  test/reject/ownership/write_borrow_lent_through_shared.rig
   4  test/reject/ownership/write_borrow_lent_through_shared_ownership.rig
   2  test/reject/ownership/write_borrow_lent_through_slice.rig
   2  test/reject/ownership/write_borrow_param_stores_local_borrow.rig
   5  test/reject/ownership/write_borrow_temporary.rig
   5  test/reject/ownership/write_borrow_temporary_handle.rig
   6  test/reject/ownership/write_borrow_through_read_borrow.rig
   4  test/reject/ownership/write_borrow_view_in_loop.rig
   4  test/reject/ownership/write_borrow_while_read_live.rig
   3  test/reject/ownership/write_method_while_borrowed.rig
   6  test/reject/ownership/write_slice_aliasing.rig
   3  test/reject/ownership/write_slice_as_read.rig
   2  test/reject/ownership/write_slice_escape.rig
   6  test/reject/ownership/write_slice_escape_ownership.rig
   3  test/reject/ownership/write_through_borrow_field_keeps_loan.rig
   1  test/reject/ownership/write_through_borrow_field_needs_write_access.rig
  16  test/reject/ownership/write_through_borrow_field_read_path.rig
   3  test/reject/ownership/write_through_borrow_field_stores_borrow.rig
   2  test/reject/ownership/write_through_moved_borrow.rig
   2  test/reject/std/text_iterators.rig
   1  test/reject/syntax/detached_prefix_read.rig
   1  test/reject/syntax/detached_prefix_type.rig
   1  test/reject/syntax/detached_prefix_write.rig
   2  test/reject/syntax/fixed_assign_touching_operand.rig
   1  test/reject/syntax/for_vec_needs_borrow.rig
   2  test/reject/syntax/habit_ampersand_borrow.rig
   2  test/reject/syntax/read_receiver_sigil_on_writer.rig
   4  test/reject/types/array_as_slice.rig
   1  test/reject/types/array_fill_rejected.rig
   1  test/reject/types/assign_read_borrow_param.rig
   1  test/reject/types/borrow_number_literal_range.rig
  10  test/reject/types/borrowed_callable_types.rig
   2  test/reject/types/box_match_owned.rig
   4  test/reject/types/box_value_access.rig
   1  test/reject/types/bytes_write_read_only.rig
   1  test/reject/types/cell_non_copy_element.rig
   2  test/reject/types/cell_vec_element_place.rig
   2  test/reject/types/clone_borrowed_resource.rig
   4  test/reject/types/closure_lending_hints.rig
   6  test/reject/types/closure_lending_hints_ownership.rig
   1  test/reject/types/closure_literal_as_owned_binding.rig
   1  test/reject/types/closure_param_names_local.rig
   3  test/reject/types/drop_decl_read_self.rig
   1  test/reject/types/elem_method_on_temporary.rig
   2  test/reject/types/equality_view_struct.rig
   4  test/reject/types/generic_fn_borrow_arg.rig
   1  test/reject/types/generic_fn_borrowed_operand_missing.rig
   5  test/reject/types/generic_fn_escaping_borrow.rig
   3  test/reject/types/generic_with_methods_borrow_arg.rig
  10  test/reject/types/handle_of_borrow.rig
   1  test/reject/types/lent_closure_to_generic_borrow.rig
   1  test/reject/types/match_guard_changes_subject.rig
   4  test/reject/types/match_write_bool.rig
   3  test/reject/types/method_consume_through_borrow.rig
   2  test/reject/types/method_write_without_bang.rig
   3  test/reject/types/missing_borrow_sigil.rig
   1  test/reject/types/module_constant_write.rig
   1  test/reject/types/owned_closure_literal_lent.rig
   1  test/reject/types/owned_closure_literal_to_borrowed_param.rig
   4  test/reject/types/read_receiver_where_result_borrow_expected.rig
   2  test/reject/types/receiver_move_sigil_misuse.rig
   4  test/reject/types/receiver_sigil_bool_result.rig
   1  test/reject/types/receiver_sigil_reads.rig
   4  test/reject/types/replace_swap_misuse.rig
   2  test/reject/types/sequence_get_owning.rig
   3  test/reject/types/slice_array_without_borrow.rig
   3  test/reject/types/slice_element_write.rig
   5  test/reject/types/slice_fill_copy_borrows.rig
   9  test/reject/types/slice_write.rig
   2  test/reject/types/string_byte_and_len_write.rig
   4  test/reject/types/text_forms.rig
   1  test/reject/types/text_lent_as_string.rig
   1  test/reject/types/type_print_round_trip.rig
   1  test/reject/types/unread_borrow_and_closure_locals.rig
   1  test/reject/types/vec_bad_element.rig
   9  test/reject/types/write_borrow_bool_as_not.rig
   5  test/reject/types/write_borrow_immutable_bindings.rig
   4  test/reject/types/write_borrow_read_slice.rig
   2  test/reject/types/write_slice_needs_sigil.rig
   3  test/reject/types/write_through_borrow_field_mismatch.rig
   1  test/reject/types/write_through_temporary.rig
```

## Appendix B. Tracked paths containing the word (305)

```text
test/behavior/emit/borrow_result_operands.rig
test/behavior/emit/borrow_result_values.rig
test/behavior/emit/clone_borrowed_handle_result.rig
test/behavior/emit/dropped_borrow_binding.rig
test/behavior/emit/generic_read_borrow_instances.rig
test/behavior/emit/generic_read_borrow_of_vec_element.rig
test/behavior/emit/match_on_borrow.rig
test/behavior/emit/match_on_borrow_call.rig
test/behavior/emit/optional_borrow_from_branch.rig
test/behavior/emit/read_borrow_large_by_pointer.rig
test/behavior/emit/read_borrow_local_rebind.rig
test/behavior/emit/write_borrow_copy_element.rig
test/behavior/ownership/as_borrows_cell_and_fresh.rig
test/behavior/ownership/as_borrows_optional_value.rig
test/behavior/ownership/as_borrows_through_paths.rig
test/behavior/ownership/borrow_ends_at_last_use.rig
test/behavior/ownership/borrow_ends_with_scope.rig
test/behavior/ownership/borrow_in_local_struct.rig
test/behavior/ownership/borrow_param_field_returned.rig
test/behavior/ownership/borrow_param_returned.rig
test/behavior/ownership/borrow_released_by_drop.rig
test/behavior/ownership/borrow_slice_element_returned.rig
test/behavior/ownership/borrowed_temporary_lives_for_statement.rig
test/behavior/ownership/builtin_result_does_not_borrow_receiver.rig
test/behavior/ownership/cell_set_from_borrowed_copy.rig
test/behavior/ownership/clone_borrowed_handle.rig
test/behavior/ownership/closure_capture_borrows.rig
test/behavior/ownership/closure_passes_captured_borrow.rig
test/behavior/ownership/closure_returns_captured_borrow.rig
test/behavior/ownership/copy_write_borrow_read_or_moved.rig
test/behavior/ownership/defer_reads_borrow_of_earlier_local.rig
test/behavior/ownership/drop_body_borrows_older_value.rig
test/behavior/ownership/field_store_through_local_write_borrow.rig
test/behavior/ownership/match_payload_write_borrow.rig
test/behavior/ownership/match_subject_borrow_ends_with_bindings.rig
test/behavior/ownership/method_returns_borrow.rig
test/behavior/ownership/move_write_borrow_into_local.rig
test/behavior/ownership/move_write_borrow_of_copy.rig
test/behavior/ownership/moved_borrow_ends_with_call.rig
test/behavior/ownership/read_borrow_branch_value_keeps_owner.rig
test/behavior/ownership/read_borrow_of_owner_is_not_dropped.rig
test/behavior/ownership/read_borrow_returned_handle.rig
test/behavior/ownership/rebind_local_write_borrow.rig
test/behavior/ownership/rebind_local_write_borrow_by_move.rig
test/behavior/ownership/return_write_borrow.rig
test/behavior/ownership/store_through_local_write_borrow.rig
test/behavior/ownership/store_through_nested_borrow_field.rig
test/behavior/ownership/write_borrow_arg_plain_pointee.rig
test/behavior/ownership/write_borrow_args_of_several_types.rig
test/behavior/ownership/write_borrow_in_payload.rig
test/behavior/ownership/write_borrow_lent_as_copied_read.rig
test/behavior/ownership/write_borrow_lent_on.rig
test/behavior/ownership/write_borrow_view.rig
test/behavior/ownership/write_borrows_in_sibling_calls.rig
test/behavior/ownership/write_through_borrow_element.rig
test/behavior/ownership/write_through_borrow_field.rig
test/behavior/ownership/write_through_local_borrow.rig
test/behavior/runtime/cell_borrow_sees_updates.rig
test/behavior/runtime/cell_set_through_read_borrow.rig
test/behavior/runtime/closure_captures_write_borrow.rig
test/behavior/runtime/closure_clone_captures_borrowed_handle.rig
test/behavior/runtime/owned_closure_borrowed_param.rig
test/behavior/runtime/owned_closure_through_borrow.rig
test/behavior/runtime/vec_len_through_borrows.rig
test/behavior/types/borrow_and_string_branches.rig
test/behavior/types/borrow_number_literal.rig
test/behavior/types/borrowed_copy_reads_as_value.rig
test/behavior/types/box_write_borrow_param.rig
test/behavior/types/callable_vs_function_borrows.rig
test/behavior/types/copy_from_write_borrow.rig
test/behavior/types/forward_borrowed_param.rig
test/behavior/types/generic_fn_borrowed_operands.rig
test/behavior/types/read_borrowed_int.rig
test/behavior/types/rebind_borrow_local.rig
test/behavior/types/text_borrows_as_strings.rig
test/behavior/types/write_borrow_bool.rig
test/behavior/types/write_borrow_calls_mutating_method.rig
test/behavior/types/write_borrow_int_param.rig
test/behavior/types/write_borrow_param_replaces_value.rig
test/corpus/R11a-P3_borrowed_owned_closure_call.rig
test/corpus/R15-repro-copy_keeps_source_borrowed.rig
test/corpus/R3c1-t05_borrow.rig
test/corpus/R3c1-t07_retborrow.rig
test/corpus/audit-ownership-a02_borrowed_handle_owned_closure.rig
test/corpus/audit-ownership-b06_nullish_return_borrow.rig
test/corpus/audit-ownership-c04_while_step_uses_borrow.rig
test/corpus/audit-ownership-e05_take_while_field_borrowed.rig
test/corpus/audit-ownership-f08_closure_returns_capture_borrow.rig
test/corpus/audit-ownership-f09_closure_returns_borrow_of_local.rig
test/corpus/audit-ownership-f13_closure_write_capture_reborrow_call.rig
test/corpus/audit-ownership-g04_view_array_of_borrows.rig
test/corpus/audit-ownership-g05_optional_borrow_drop.rig
test/corpus/audit-ownership-g08_method_returns_self_borrow.rig
test/corpus/audit-ownership-g13_write_borrow_stored_in_view.rig
test/corpus/audit-ownership-h08_loop_borrow_carried.rig
test/corpus/audit-ownership-h09_loop_borrow_carried2.rig
test/corpus/audit-ownership-h11_loop_nested_break_borrow.rig
test/corpus/audit-ownership-i10_replace_value_borrows_place.rig
test/corpus/audit-ownership-k10_box_borrow_value_then_move_box.rig
test/corpus/audit-ownership-l04_defer_borrow_later_var.rig
test/corpus/audit-ownership-m07_drop_body_stash_self_borrow.rig
test/corpus/audit-ownership-m12_consuming_method_on_borrow.rig
test/corpus/audit-ownership-o12_reborrow_local_wb_then_use.rig
test/corpus/audit-ownership-w01_fill_write_borrow.rig
test/corpus/audit-ownership-w05_fill_borrow_from_fn.rig
test/corpus/audit-tests-probes-rg01_missing_read_borrow_arg.rig
test/corpus/audit-tests-probes-rg02_missing_write_borrow_arg.rig
test/corpus/audit-tests-probes-rg106_borrow_outlives.rig
test/corpus/audit-tests-probes-rg16_move_borrowed.rig
test/corpus/audit-tests-probes-rg17_return_borrow_of_local.rig
test/corpus/audit-tests-probes-rg36_borrow_of_temp_stored.rig
test/corpus/audit-tests-probes-rg45_write_borrow_twice.rig
test/corpus/audit-tests-probes-w_return_borrow_param_wrong.rig
test/corpus/audit-tests-probes-y05_temp_borrow_rt.rig
test/corpus/audit-tests-probes-y06_temp_borrow_plain.rig
test/corpus/audit-tests-probes-y08_local_borrow_return.rig
test/corpus/audit-tests-probes-y09_temp_borrow_scope.rig
test/corpus/docs-p-forborrow.rig
test/corpus/docs-p-qqborrow.rig
test/corpus/purity-designer-r11_write_borrow_twice_call.rig
test/corpus/purity-principles-p20_bareborrow.rig
test/corpus/purity-principles-p27_tempborrow.rig
test/corpus/purity-rustzig-probes-q1_handle_borrow.rig
test/corpus/review-box-repro-h3_typed_borrow_local.rig
test/corpus/review-box-repro-m2_generic_opt_borrow.rig
test/corpus/review-place-b1-p010_fixed_borrow.rig
test/corpus/review-place-b1-p015_global_borrow.rig
test/corpus/review-place-b1-p016_const_borrow.rig
test/corpus/review-place-b10-y002_temp_field_cell_borrow.rig
test/corpus/review-place-b10-y003_ctor_field_cell_borrow.rig
test/corpus/review-place-b10-y004_temp_elem_cell_borrow.rig
test/corpus/review-place-b10-y006_temp_field_nocell_borrow.rig
test/corpus/review-place-b10-y008_asread_cell_borrow_explicit.rig
test/corpus/review-place-b12-k003_wb_temp_readborrow.rig
test/corpus/review-place-b2-q003_temp_write_borrow.rig
test/corpus/review-place-b2-q004_temp_field_write_borrow.rig
test/corpus/review-place-b2-q030_shared_write_borrow.rig
test/corpus/review-place-b2-q054_cellvec_borrow_elem.rig
test/corpus/review-place-b6-u004_mod_const_borrow/geo.rig
test/corpus/review-place-b6-u004_mod_const_borrow/main.rig
test/corpus/review-place-b7-v001_reslice_elem_borrow.rig
test/corpus/review-place-b7-v004_range_local_elem_borrow.rig
test/corpus/review-place-b7-v021_wt_store_borrow.rig
test/corpus/review-place-b7-v022_wt_value_holding_borrow.rig
test/corpus/review-place-b7-v023_wt_value_holding_borrow_escape.rig
test/corpus/review-place-b8-w001_readloop_cell_borrow.rig
test/corpus/review-place-b8-w002_matchread_cell_borrow.rig
test/corpus/review-place-b8-w003_asread_cell_borrow.rig
test/corpus/review-place-b8-w004_matchwrite_cell_borrow.rig
test/corpus/review-place-b8-w006_copyloop_cell_borrow.rig
test/corpus/review-place-b8-w007_temp_cell_borrow.rig
test/corpus/review-place-b8-w008_param_cell_borrow.rig
test/corpus/review-place-b8-w011_borrowed_call_cell.rig
test/corpus/review-place-b9-x019_write_borrow_of_shared_field.rig
test/corpus/review-place-b9-x023_readborrow_local_assign.rig
test/corpus/review-place-b9-x024_readborrow_local_field_assign.rig
test/corpus/review-place-b9-x036_cell_set_call_readborrow.rig
test/corpus/seams-surface-b06_held_borrow.rig
test/corpus/seams-surface-e03b_vec_handle_borrow.rig
test/corpus/syntax-review-designer-p03_vecborrow.rig
test/corpus/syntax-review-designer-p08_owned_cb_borrow.rig
test/corpus/syntax-review-designer-p33_cell_vec_borrow.rig
test/reject/modules/cross_borrow_mode/a.rig
test/reject/modules/cross_borrow_mode/main.rig
test/reject/modules/imported_borrow_stored_through_write_borrow/a.rig
test/reject/modules/imported_borrow_stored_through_write_borrow/main.rig
test/reject/modules/imported_write_borrow_holder_copy/main.rig
test/reject/modules/imported_write_borrow_holder_copy/wv.rig
test/reject/ownership/as_bare_write_borrow.rig
test/reject/ownership/as_borrow_aliasing.rig
test/reject/ownership/as_borrow_aliasing_ownership.rig
test/reject/ownership/assign_borrow_to_local_write_borrow.rig
test/reject/ownership/borrow_chain_through_long_loop.rig
test/reject/ownership/borrow_chosen_by_if.rig
test/reject/ownership/borrow_escapes_by_break.rig
test/reject/ownership/borrow_escapes_loop_body.rig
test/reject/ownership/borrow_field_of_call_result.rig
test/reject/ownership/borrow_in_returned_struct.rig
test/reject/ownership/borrow_of_temporary_escapes.rig
test/reject/ownership/borrow_outlives_inner_scope.rig
test/reject/ownership/borrow_result_owning_value.rig
test/reject/ownership/borrow_returned_from_fn.rig
test/reject/ownership/borrow_slice_element_outlives.rig
test/reject/ownership/borrow_stored_by_callee.rig
test/reject/ownership/borrow_stored_in_field.rig
test/reject/ownership/borrow_stored_through_borrowed_param.rig
test/reject/ownership/borrow_stored_through_passed_write_borrow.rig
test/reject/ownership/borrowed_callable_escape.rig
test/reject/ownership/borrowed_callable_results.rig
test/reject/ownership/box_borrows.rig
test/reject/ownership/box_borrows_ownership.rig
test/reject/ownership/capture_write_borrow_of_copy.rig
test/reject/ownership/cell_store_value_holding_borrow.rig
test/reject/ownership/clone_of_shared_view_keeps_borrow.rig
test/reject/ownership/clone_write_borrow_holder.rig
test/reject/ownership/closure_capture_borrow_rules.rig
test/reject/ownership/closure_capture_borrow_rules_ownership.rig
test/reject/ownership/closure_holds_borrow.rig
test/reject/ownership/closure_result_borrows_captured_borrow.rig
test/reject/ownership/closure_returns_local_borrow.rig
test/reject/ownership/closure_tail_borrows_local.rig
test/reject/ownership/coalesce_jump_borrowed_optional.rig
test/reject/ownership/copy_field_borrow_keeps_loan.rig
test/reject/ownership/copy_read_while_write_borrow_live.rig
test/reject/ownership/copy_write_borrow_duplicated.rig
test/reject/ownership/defer_reads_borrow_of_later_local.rig
test/reject/ownership/defer_stores_borrow.rig
test/reject/ownership/defer_stores_borrow_at_break.rig
test/reject/ownership/defer_stores_borrow_of_scope_var.rig
test/reject/ownership/defer_stores_borrow_past_propagate.rig
test/reject/ownership/drop_body_reads_borrow_stored_through_moved_write_borrow.rig
test/reject/ownership/drop_body_reads_younger_borrow.rig
test/reject/ownership/drop_borrowed_param.rig
test/reject/ownership/field_store_through_local_write_borrow_outlives.rig
test/reject/ownership/for_move_borrowed_vec.rig
test/reject/ownership/for_move_element_keeps_borrow.rig
test/reject/ownership/for_write_borrow_elements.rig
test/reject/ownership/generic_as_borrowed.rig
test/reject/ownership/index_of_borrowed_place.rig
test/reject/ownership/lend_held_write_borrow_needs_mutable.rig
test/reject/ownership/loop_element_of_made_array_borrows.rig
test/reject/ownership/loop_value_borrows_loop_local.rig
test/reject/ownership/match_borrow_subject_misuse.rig
test/reject/ownership/match_consume_borrow.rig
test/reject/ownership/match_field_payload_through_borrow.rig
test/reject/ownership/match_payload_write_borrow_twice.rig
test/reject/ownership/match_tail_payload_of_borrowed.rig
test/reject/ownership/move_capture_borrowed_param.rig
test/reject/ownership/move_capture_borrowed_param_lambda.rig
test/reject/ownership/move_field_from_borrowed_param.rig
test/reject/ownership/move_field_from_borrowed_self.rig
test/reject/ownership/move_payload_of_borrowed_scrutinee.rig
test/reject/ownership/moved_borrow_keeps_loans_in_call.rig
test/reject/ownership/nll_borrowed_view.rig
test/reject/ownership/nll_closure_holds_borrow.rig
test/reject/ownership/nll_drop_reaches_borrow.rig
test/reject/ownership/nll_reborrow_through_write.rig
test/reject/ownership/nll_returned_borrow_still_used.rig
test/reject/ownership/owned_closure_captures_borrow.rig
test/reject/ownership/read_borrow_after_drop.rig
test/reject/ownership/read_borrow_after_move.rig
test/reject/ownership/read_while_write_borrow_live.rig
test/reject/ownership/receiver_borrow_with_move_arg.rig
test/reject/ownership/repoint_local_write_borrow.rig
test/reject/ownership/resource_temp_borrow.rig
test/reject/ownership/return_borrow_chosen_by_if.rig
test/reject/ownership/return_borrow_of_local.rig
test/reject/ownership/return_struct_with_local_borrow.rig
test/reject/ownership/shared_field_write_borrow.rig
test/reject/ownership/signal_subscriber_borrow.rig
test/reject/ownership/store_borrow_through_held_write_borrow.rig
test/reject/ownership/store_borrow_through_local_write_borrow.rig
test/reject/ownership/store_through_nested_borrow_outlives.rig
test/reject/ownership/store_through_write_borrow_outlives.rig
test/reject/ownership/string_borrow_in_cell.rig
test/reject/ownership/take_through_borrow_of_temporary.rig
test/reject/ownership/text_view_through_write_borrow.rig
test/reject/ownership/vec_for_no_borrow.rig
test/reject/ownership/while_step_uses_borrow_binding.rig
test/reject/ownership/write_borrow_copied.rig
test/reject/ownership/write_borrow_copied_by_binding.rig
test/reject/ownership/write_borrow_field_lent_to_struct.rig
test/reject/ownership/write_borrow_holder_passed_bare.rig
test/reject/ownership/write_borrow_in_struct_copied.rig
test/reject/ownership/write_borrow_lent_bare.rig
test/reject/ownership/write_borrow_lent_bare_unwritable.rig
test/reject/ownership/write_borrow_lent_through_read_borrow.rig
test/reject/ownership/write_borrow_lent_through_shared.rig
test/reject/ownership/write_borrow_lent_through_shared_ownership.rig
test/reject/ownership/write_borrow_lent_through_slice.rig
test/reject/ownership/write_borrow_param_stores_local_borrow.rig
test/reject/ownership/write_borrow_temporary.rig
test/reject/ownership/write_borrow_temporary_handle.rig
test/reject/ownership/write_borrow_through_read_borrow.rig
test/reject/ownership/write_borrow_view_in_loop.rig
test/reject/ownership/write_borrow_while_read_live.rig
test/reject/ownership/write_method_while_borrowed.rig
test/reject/ownership/write_through_borrow_field_keeps_loan.rig
test/reject/ownership/write_through_borrow_field_needs_write_access.rig
test/reject/ownership/write_through_borrow_field_read_path.rig
test/reject/ownership/write_through_borrow_field_stores_borrow.rig
test/reject/ownership/write_through_moved_borrow.rig
test/reject/syntax/for_vec_needs_borrow.rig
test/reject/syntax/habit_ampersand_borrow.rig
test/reject/types/assign_read_borrow_param.rig
test/reject/types/borrow_number_literal_range.rig
test/reject/types/borrowed_callable_types.rig
test/reject/types/clone_borrowed_resource.rig
test/reject/types/generic_fn_borrow_arg.rig
test/reject/types/generic_fn_borrowed_operand_missing.rig
test/reject/types/generic_fn_escaping_borrow.rig
test/reject/types/generic_with_methods_borrow_arg.rig
test/reject/types/handle_of_borrow.rig
test/reject/types/lent_closure_to_generic_borrow.rig
test/reject/types/method_consume_through_borrow.rig
test/reject/types/missing_borrow_sigil.rig
test/reject/types/owned_closure_literal_to_borrowed_param.rig
test/reject/types/read_receiver_where_result_borrow_expected.rig
test/reject/types/slice_array_without_borrow.rig
test/reject/types/slice_fill_copy_borrows.rig
test/reject/types/unread_borrow_and_closure_locals.rig
test/reject/types/write_borrow_bool_as_not.rig
test/reject/types/write_borrow_immutable_bindings.rig
test/reject/types/write_borrow_read_slice.rig
test/reject/types/write_through_borrow_field_mismatch.rig
```
