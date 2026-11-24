# D: index checks on Trig's per-node Lists

A design note for the owner, through Rig. Nothing is built. Trig faeb512b, Rig 383a1b2b5; the
census is `census-nocheck.md`.

**In one line:** the rule asked for (an id minted by a push to a List that only grows is below
that List's length, so its index needs no test) holds for one List value, and Trig's ids cross
List values. The sound form is Table's, which Rig already has. This note proposes no new
language rule. It proposes a store per owner of many files, written with today's `Table` and
`Slot`, for Trig to measure.

## 1. The problem in Trig's code

Every node read indexes a per-file List by an id that the program knows is in range:

```
# src/ast/ast.rig:400 — 5.4% of all check branches on its own
pub fun kind(?@, n: Node) -> Kind
  @recs[n.id].kind

# src/ast/ast.rig:501 — ids minted by a push; recs and locs grow side by side
fun new_node(!@, kind: Kind, flags: U32) -> Node
  !@recs.push(NodeRec(kind: kind, keyword: .Unknown, parent: 0, data: U32(@words.len), flags: flags | @on_create_flags))
  !@locs.push(NodeLoc(pos: -1, end: -1))
  Node(id: U32(@recs.len - 1))

# src/ast/ast.rig:870 — ids read back out of plain U32 data
sub parent_child(!@, i: Int, p: U32)
  w = @words[i]
  if w != 0
    @recs[w].parent = p

# src/ast/binding.rig:131 — another object's Lists, sized by a count, not by pushes
b.node_symbol = List.filled(node_count + 1, SymbolId(0))
b.node_flow = List.filled(node_count + 1, FlowId(0))
```

The checker pairs an id with its file and reaches that file's arena:
`tree = ?@program.files[Int(reference.file) -% 1].ast` (src/checker/flow.rig:400), then
`tree.kind(reference.node)`.

**Census (webpack --noCheck, c1).** Category d is 27.6% of all weighted check branches, 30.7%
of the live ones, and about 1.53% of c1 cycles. With d-rec (ranges inside a node's record) it is
39.1% of live branches, about 1.95% of cycles. By where the id comes from (points of all
branches): a `Node`, `NodeList` or `TextId` passed into the arena's methods, 17.9 (`kind` 5.4,
`finish_node` 2.1, `flags` 1.3); an id read back from `words` or `list_nodes`, 5.5
(`parent_list` 2.9, `parent_child` 1.5); the binder's `U32` ids into `flows`, `symbols`,
`node_flow`, 3.7; other, 0.4.

**A correction to the census.** The checker's store is already Tables and Slots
(`store_generated.rig:555`, emitted as `rig.Table(Type, 134217728)`), so
`self.store.types.at(t)` makes no test (`table.zig`'s `at`). The static count's 1,803 checker d
sites come from `classify.py` matching every `.at(`, Table reads included. The weighted shares
above are not affected, because they count only real branches to a panic. But "d probably grows
on full runs" has no support. Trig's own trial (docs/ceiling.md, 2026-11-04) put all the
node-accessor frames together at 1.3 to 2% of checker cycles.

## 2. The rule

### Why "minted by push, grow-only" is not enough

The guarantee "every id is below the length" belongs to one List value. In Trig:

- **Ids cross values.** There is one `Ast` per file, and a `Node` is only a number. An id from a
  50,000-node file, given to a 100-node file's arena, reads past its buffer.
- **Ids come back from data.** There are 260 `Node(id: ...)` sites, made from words, list
  entries, and the arithmetic in `rebase`. `Node` is an object with a public `id`.
- **Arenas are cleared and refilled.** `take_fitted` (ast.rig:281) clears every List and pushes
  the nil entries again. `fit` replaces each List with a clone.
- **A family spans objects.** `Binding`'s per-node Lists are filled to another object's count.

Removing the test soundly needs one of two things. Either the type ties each id to one value (a
brand), or every value of the store type has room for every id the type allows. Rig has no
brand: there are no lifetimes in types, and an id kept as a `U32` in `words` would lose one
anyway. The second is `Table[T, n]`'s guarantee: "a `Slot[n]` is in range of every
`Table[_, n]`".

### Proposed: a store per owner of many files, with today's Table and Slot

Trig keeps its node handles as objects, so `Node`, `NodeList` and `TextId` stay distinct types,
and gives each one a slot field. The per-node stores become Tables owned by each parse worker,
or by the program, not by each file. A file becomes a range of its owner's store. This runs on
Rig today (checked in the scratchpad):

```rig
NODES = 1 << 27

obj Node
  id: Slot[NODES] = 0

obj NodeRec
  kind: U32 = 0

obj NodeLoc
  pos: I32 = 0

obj Nodes
  recs: Table[NodeRec, NODES]
  locs: Table[NodeLoc, NODES]

  fun add(!@, kind: U32, pos: I32) -> Node
    s = !@recs.push(NodeRec(kind: kind))
    @locs[s] = NodeLoc(pos: pos)
    Node(id: s)

sub main()
  ns = Nodes(recs: Table(), locs: Table())
  _ = !ns.add(0, -1)
  a = !ns.add(7, 42)
  f = *Frozen(<ns)
  print(f.recs[a.id].kind, f.locs[a.id].pos)
```

```output
7 42
```

**What it lowers to.** It lowers to what emit writes now: `self.recs.at(n.id).kind`, a load at
`base + 16 * id`, with no length read and no test.

- **Parallel stores.** One Table is pushed and the others are written at its slot
  (`@locs[s] = ...`). Every slot of a Table exists from the start, so no two lengths need to
  agree. `Binding`'s `List.filled(node_count + 1, 0)` becomes a Table that is never filled:
  a slot nothing has written reads 0.
- **Ids kept in other objects.** A `Slot[2^27]` field is 4 bytes, the same as Trig's `U32`.
  `NodeRef(file, node)` stays as it is, with `node` an id in the owner's space.
- **Ids from words.** `Slot[NODES].of(w)` makes one test against a constant, with no length
  loaded. Words stay `U32`, because their meaning depends on `LAYOUT`.
- **Pop, truncation, clearing.** A Table has none of them, and the store needs none. Pages
  nothing touched cost nothing, so `fit` and `take_fitted` (one copy of each List per file)
  go away.
- **Moves.** A Table is an owning value. After parsing and binding, the owner's store moves
  behind `*Frozen` and the checker tasks read it. An id stays in range of every Table of its
  `n`. An id used on the wrong owner's store reads a record that exists, as Table's meaning
  already says, and never memory past the end.

**Why not one store per file.** A Table takes at least one page for each Table touched, and
its `n` is the same for every value. With about a dozen node-indexed Tables a file, a 100-node
file holds at least 192 KiB on the Mac (16 KiB pages), against about 6 KiB of records today. Its
address space is `n × size` for each Table. With `n = 2^24`, about 1 GiB a file fills the Mac's
2 TiB of Table regions at about 2,000 files. A file over `n` nodes panics.

## 3. How it fits CORE

Ownership does not change. `Table[T, n]` and `Slot[n]` are CORE §10's "Tables" (built), and
this note adds nothing to them. The fact "this index needs no test" is the type `Slot[n]`, which
typecheck records once. Emit reads `facts.tableElem` and the index's type, as `emitIndex` does
today, and decides nothing. The List rule this note turns down would have needed a brand for
each value, a change to the type system that CORE does not have.

## 4. What it removes and what it leaves

If the AST's stores and the binder's become Tables, it removes the method-entry ids (17.9
points) and the binder's ids (3.7): about 21.6 of d's 27.6 points. That is 24% of live check
branches, about 1.2% of c1 cycles on webpack --noCheck, and less on full runs, where the checker
(already on Tables) dominates. It leaves the ids from words (5.5 points, each still one `of`
test, now against a constant), d-rec (7.6), and categories a, b+, c, std and zig. It adds
zero-filled page faults for fresh pages (Trig's trial saw 150 to 930 more a run) and saves
`take_fitted`'s copies. The net is unknown until Trig measures it against its bar.

## 5. Alternatives

- **The List handle rule as asked.** Unsound across values (§2). Limiting it to a store that
  exists once in a program would make it sound, but the compiler cannot check that.
- **Table per file.** Sound and runs today, but it costs pages and address space (§2).
- **A bounded List** (census rule a). It gives `len <= bound`, not `id < len`, so it removes
  no d test.
- **The proof pass alone.** It could carry `below` facts from `new_node` into `finish_node`
  and an invariant `len(recs) == len(locs)` that merges two tests into one. The internal ids
  need object invariants over `words`, which is census rule c's open design. The share is small
  for a lot of work.
- **Masking or clamping to the capacity.** No branch, but a bad id silently reads some other
  record, against North Star 1.
- **Doing nothing.** About 1.5% of cycles on parse-heavy runs, less on full runs; the tests are
  well predicted. Defensible for Rig, since Table already covers the sound path.

The proposed path wins because it adds no mechanism (one word, Table, for one idea) and leaves
the speed question with Trig, which owns its performance.

## 6. Naming

No new syntax. The open word is what the docs call several Tables that share one slot type,
which STD.md's Table section would teach:

- **store**: `obj NodeStore` holding `recs` and `locs`; a hint
  ``an `Int` is no slot of this store: enter it with `Slot[NODES].of(i)` ``; "A file's nodes
  are a range of its worker's store."
- **arena**: `obj NodeArena`; ``an `Int` is no slot of this arena: ...``; "Each parse worker
  fills one arena." Zig's arena frees all at once, a different meaning.
- **family**: `obj NodeFamily`; ``an `Int` is no slot of this family: ...``; "Tables of one
  family share one slot type." A coined use.

STD.md already says "a store of records that only grows", so **store** is the default.

## 7. Open questions for the owner

1. Rig adds no handle rule for Lists, and the record says why (§2). *Default: agree.*
2. STD.md's Table section teaches the pattern: one store per owner of many files, push one
   Table and write the parallel ones at its slot, with the page reasons. *Default: yes, docs
   only.*
3. Trig decides whether to move its AST and binding stores to per-worker Tables, measured on its
   bar. *Default: Trig's call, after the work it has queued.*
4. Before this is filed, fix the census so its checker column skips Table reads, and remove
   "d grows on full runs". *Default: yes.*
5. A brand for each value (ids tied to one store by type) stays out of Rig. *Default: out
   unless a second program needs it.*
6. The docs' word for §6. *Default: store.*
