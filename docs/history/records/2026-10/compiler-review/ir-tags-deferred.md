# The IR-tags row: skipped, its items moved to the rewrite (2026-11-01)

After rows 33G (#833, #836) moved eleven of the parser wrapper's thirteen side tables into the IR,
a follow-up row was to finish the job. Rig - Swiss skipped it (option 1), on Rig language
analysis's reading of the code at 928b44bf2. These go to the rewrite instead.

## What remains beside the tree, and why

| Item | What it is | Why it waits for the rewrite |
|---|---|---|
| `Parser.receiver_sigils` | the node ids of the `read`, `write`, and `move` written before a method call (`!v.push(x)`), not in parentheses; typecheck asks `isReceiverSigil` 23 times | As an IR tag it adds a slot to the most common nodes in the IR (`(write x)` becomes `(write x _)`), which every pass, `rig normalize`, the `--facts` dumps, and the oracle's reader would each have to be checked against, for no gain in speed, safety, or emitted Zig. It has been filled from the tree (the `paren` node) since #833. |
| `Parser.paren_suffixes` | the node ids of the `share` and `weak` whose operand has a `?` inside parentheses (`*(T?)`) | Likewise; filled from the tree since #833. |
| `Parser.pad_homes` | the closure start each hidden parameter of a padded closure (`padLambda`) points at; the parameter's leaf holds a position past the end of the source | Facts are still keyed by source position (`facts.names: FastMap(u32, SymbolId)`, sema.zig:1821; 33A, #834, made the tables faster but kept the keys), so each hidden parameter needs a position no other leaf has. It goes when facts are keyed by node. |
| `facts.names` and the other position-keyed facts | sema's facts keyed by a leaf's or node's source position | The rewrite keys facts by node id, in arrays (the review's finding 2), which also lets padded parameters be ordinary hidden leaves. |
| `Checker.parenthesized` | compares a write call's place with the start of a `for` source, to know a `for` source's call | For a leaf the position is its identity, so a "node" comparison is the same test written differently; in the rewrite the lowered `for` names its source's call directly. |
| `Parser.detached` | the method declarations set aside for resolve to report | Kept by design: a list for diagnostics, not a lookup. |

## For the rewrite

The tree records how each lend was written (short or parenthesized), and how a handle's suffix
groups, as it is parsed; facts are keyed by node; hidden leaves need no invented positions.
