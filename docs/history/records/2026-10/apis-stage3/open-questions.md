# APIs Stage 3: open questions (2026-10-23)

What the record ([docs/design/apis.md](../../../../design/apis.md),
its panels, and this refresh) does not settle, each with a default and
its reason. The refreshed Stage 3 section is written to these defaults;
"approve the defaults" settles all of them.

1. **An API method's failure: exactly the API's set.** An
   implementation declares the same set, union, `T!`, or set parameter;
   never a narrower one. *Reason:* a set is part of the result's type
   and its fields' slot, which one body written for every instance
   receives; a narrower set gives a caller through the bound nothing.
2. **A set each provider chooses** (`error Fail` in an API, read
   `R.Fail`): waits for std's I/O sets (R3-3). *Reason:* the I/O
   readers are its first real use, and their names are the owner's.
3. **Stage 1's `!` on an unbounded `T`:** the consolidation fixes the
   `Int!!` message and keeps "any error"; a set is said by a bound.
   *Reason:* one rule for each; guessing the frame's set would add a
   second inference path for a case a bound states.
4. **Witnesses of a generic type are parameters of the type,** not of
   its methods (the record said methods). *Reason:* a `drop`, an own
   `print`, and a Stage 1 call have nowhere to pass one; the witness
   follows from the type, so one Rig type stays one Zig type.
5. **One witness form:** a namespace per conformance
   (`__rig_impl_Shape_Square`), also for a header, rather than the type
   itself. *Reason:* defaults need a home beside the type's methods; one
   mechanism for headers and additions.
6. **Implied bounds for every parameter:** `[K: Print]` naming
   `Map[K, V]` is `K: Hash + Print` without saying it (today it must
   restate `Hash`). *Reason:* the named type already states it; Swift
   infers the same; it cuts Trig's migration from 63 declarations to
   about 32.
7. **"Public generics state their bounds" lands as Stage 3's last PR,**
   after APIs work, not with them. *Reason:* phases 1-5 only accept more
   and stay byte-identical for Trig; the one breaking change gets its
   own release note, Trig note, and script.
8. **The migration is a script,** `tools/state-bounds.py`, reading the
   compiler's own fixes, not a `rig fix` command. *Reason:* every earlier
   migration is a `tools/` script; no new CLI surface for a one-time
   change.
9. **`Iter` is derived** by the `for` loop's rule (`next(!@)` giving an
   optional), never named on a header. *Reason:* one classifier for one
   fact; a header form would let the loop and the bound disagree.
10. **Facts no API names stay per instance** in every generic, bounded
    or public: a literal's fit, freezing, a `T()` default for `Table`.
    No new built-in API in Stage 3. *Reason:* that is what is built, and
    each would need a name; add one when a signature needs it.
11. **No bounds on compile-time values** (`[n: Int]`). *Reason:* `Int`
    already says what `n` is; ranges belong to a later `requires`.
12. **`add` names a named type only:** an object, an enum, or a built-in
    type (`Int`, `String`, `List[T]`, `Slot[n]`); never a view, handle,
    optional, array, slice, or function type. *Reason:* those take their
    facts from their parts, and coherence over them is the hard case.
13. **An API method may take compile-time parameters of its own**
    (types, values, sets) through a bound; Stage 4's objects still
    exclude them. *Reason:* the API declares them, so a direct call
    passes them as any call does.
14. **`api Job: Moves` is allowed:** an API may build on the derived
    facts, checked at each provider's header. *Reason:* it is how a job
    API says its values cross, and Stage 5's `^{Job + Moves}` reads the
    same way.
15. **`*Frozen[T]` provides no API of a program's own,** and Stage 2's
    gap that it does not provide `Ord` when its value does (it forwards
    `Eq`, `Hash`, `Print`) is fixed in the consolidation. *Reason:* a
    handle is not its value; lend `?f`. Forwarding three of four is a
    surprise.
