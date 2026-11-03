# `$plain(T)` narrowing: design (panel step 1)

On origin/main 57b0360fe. `probes/run.sh RIG` runs the probes with `$plain(X)` as `($size(X) >= 0)` (output in `today.txt`).

## 1. The rule (SPEC, Generic bodies, after the copy paragraph)

> `$plain(T)` is `true` where `T` is plain data (CORE §1), a type that provides both `Copy` and `Owned`. It is known when the program compiles. In a generic body, take the block an `if` runs because `$plain(T)` holds, with the test in the condition alone or joined by `and`, and `T` a type parameter or an associated type. That block is checked with `Copy + Owned` added to `T`'s bounds, and only the instances where `T` is plain compile it. In the others it is not there, and it asks nothing of them. Everything outside the block, its `else` included, is checked for every instance as before.

**CORE: no change.** Each instance is concrete code CORE covers, and the block is a `T: Copy + Owned` body, which SPEC's Bounds covers.

**SPEC fix:** the copy sentence says "plain data", but a read-view `T` copies today (p12): write "plain data or a read view".

## 2. Desugaring

`f[T]` holding `if $plain(T) and c: A else B` is two generics:
- `f₁[T: Copy + Owned + bounds]`, where the `if` stays as `if c: A else B`;
- `f₀[T: bounds]`, where the `if` becomes `B`.

Each instance runs `f₁` when `T` is plain, else `f₀`; p15 shows SPEC accepts `f₁`'s form today. The compiler still checks once: in the block `boundApis` adds `Copy + Owned`, and each requirement and instance recorded there carries the guard.

## 3. Questions

**Q1, soundness.** `$plain(T)` is a fact of the instance, not of a moment (unlike `as`): true everywhere in a plain instance, and the block is absent from the rest.

| Case | Answer | Probe: today, rule |
|---|---|---|
| Values escape | Sound: copies leave only in plain instances; `K()` stays rejected; the join is the stricter path (p14). | p02: rejected, `2 1` |
| Closures | Narrowed where written; only plain instances make them. | p03: rejected, `hook 3 3` `1 0` |
| `defer` | Runs where the block ends (CORE §7). | p04: rejected, runs |
| `else` | Not narrowed. | p05: rejected, rejected |
| Nested generics | `twice[T]` made only where the block compiles. | p06: rejected, `2 1` |
| `and` | Narrowed; later operands run only in plain instances. | p07: rejected, `1 0 0` |
| `not` | Narrows nothing, as with `as`. | p08: rejected, rejected |
| `$plain(P[T])` | A `Bool`; narrows nothing. | p09: rejected, rejected |
| `S.Item` | Narrowed, bounded as parameters are. | p10: rejected, `2 2` |
| Bounds | Added to the written ones; `pub` needn't state them. | p11: rejected, runs |

**The hardest case (p16).** `Static` and `?String` as `T` emit one Zig instance (`keep([]const u8, …)`; `$name(T)` prints `?String` for both). If the emitted `comptime rig.isPlain(T)` were true there, a `?String` instance would run a block checked as `Owned`, which could keep a view in an owned closure past the String's drop.

Answer: `rig.isPlain` is false for slices and pointers, and objects carry Rig's `rig_plain`; Rig's fact agrees, since a `Static` type argument is the `?String` it runs as (decision 2). Running `f₀` for a plain instance is always sound.

**Q2. `$plain`, not `$copies`.**
- It is CORE §1's word. "Copies" is a §9 fact "not visible to programs".
- `$plain` is `Copy + Owned`, so no loan of `T` is left in the block. `$copies` adds only `Copy` and leaves the Cell, Signal and owned-closure checks for view instances. A rule that narrows half is the surprising one.
- It is what the Map needs, and what the owner approved (map-stage Q3).
- `$copies` would avoid p16's sentence; not enough.

**Q3.** CORE needs nothing. The SPEC paragraph meets §10: one paragraph, no exception list, a desugaring.

**Q4, the oracle.** It needs to know: it checks generic bodies, not instances, so a copy in a `pub` generic's block would be compiler-accepted and oracle-rejected. In `kinds.zig`, the block's `T` is `.plain`, as `Copy + Owned` bounds give (~40 lines).

## 4. The packed Map's fill

```rig
  sub rebuild_packed(!@, n: Int)
    if $plain(K) and $plain(V)
      filler = @es[@at[0]]                # a copy: Entry[K, V] is plain here
      slots: List[Entry[K, V]] = List.filled(n, filler)
      !@table.reset(n)
      for s, i in ?@at
        e = @es[s]
        j = @table.place_packed(hash_of(?e.key))
        slots[j] = e
        @at[i] = U32(j)
      @es = <slots
    else
      !@rebuild(n)                        # today's dense layout
```

The test must be in the condition: `if packed[K, V]()` narrows nothing.

## 5. Implementation size

| File | Work | Lines |
|---|---|---|
| typecheck.zig | `$plain`; the test in `if`, guards, `a if c else b`; `narrowed` stack; notes | ~90 |
| sema.zig | `boundApis` reads `narrowed`; regions, `blockLive(pos, inst)`; guards in `expandInstantiations` and Requirement checks | ~105 |
| ownership.zig | the same blocks; `addRequirement` skips narrowed parameters; `checkInstantiations` filter | ~40 |
| emit.zig, runtime.zig | `comptime rig.isPlain(T)`; `and` chains as nested `if`s, `else` once; `rig_plain` | ~105 |
| test/oracle | as Q4 | ~40 |
| SPEC, tests | the paragraph, examples p01/p05/p08/p16, and p01-p11 as tests under the sanitizer | ~250 |

## Owner decisions (defaults)

1. `$plain`, not `$copies`. Default: `$plain`.
2. A `Static` given as `T` is a `?String` in the body, stated once for `$name` and `$plain`. Default: yes. The other way is a distinct Zig type for `Static`, which is larger.
3. No CORE change. Default: none.
4. Fix SPEC's copy sentence. Default: yes.
