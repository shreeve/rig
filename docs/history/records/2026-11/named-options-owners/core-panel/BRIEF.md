# CORE panel: the paragraph "A spread gives an object's fields one by one"

Rig is an indentation-sensitive systems language compiling to Zig 0.17, with Rust-level memory safety through visible sigils. docs/CORE.md is its ownership model; the owner's rule: any CORE.md change is revised independently by a panel of 4-7 experts, then the coordinator synthesizes and makes the final pass.

The change under review adds one paragraph and an example to CORE §5, for the lifted limit on named-option groups and spreads (owners and read views may now ride in a group or an object update). The branch is `group-owners`, worktree /Users/shreeve/Data/Code/worktrees/rig/group-owners (read-only for you). The proposed text is in that worktree's docs/CORE.md, starting at the line "**A spread gives an object's fields one by one.**"; the diff is in core-diff.txt beside this brief.

Context to read: docs/CORE.md (the whole model; its vocabulary: place, made value, read view, write view, read-only, unusable, cell; never "borrow" or "lend"; an `obj` is an object, never a struct; `@` is self), docs/design/options.md §2-§4 and §11 step 3, and the record docs/history/records/2026-11/named-options-owners/README.md. AGENTS.md's North Star: docs claim only what runs (every `rig` block is a test), effects stay visible, ownership features fit the Core.

Known facts of the built compiler (keep every one true):
- `..v` = one keyword argument per field, `f: v.f`, evaluated where written; owning fields take the spread's sigil (`..<v` moves them, `..+v` clones them), plain fields copy; a bare `..v` that would hand over an owner is refused; `..<v` that moves nothing is refused; `..?v` and `..!v` are refused.
- A group `..net: Net` is one parameter per field; the body reads `net` as an object parameter; `from net` / `keeps net` name its fields that could hold a view; a field's bare name in from/keeps is refused.
- A type with a `drop` body or a `unique` type is never a group and is never updated (not even by `..+`) — pending the owner, since options.md §11 step 3 said "updated only by `..+p` or a whole move" and CORE §2 gives a drop type no `+`.

Your job: revise the paragraph (and the example if needed) from your angle so it is exact, short, consistent with the rest of CORE, and teaches the rule. Do not change any fact. Write your full revised text and your reasons to a file named after your role in this folder (e.g. purist.md). Final reply: at most 400 words — your revised paragraph and the 2-3 changes that matter most. Don't edit the worktree, don't run the whole suite, never touch pup or burst. You may run `bin/rig run` on a temp copy of an example (in mktemp -d) from the worktree to check it.
