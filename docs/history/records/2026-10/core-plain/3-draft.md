# `$plain(T)` narrowing: revised draft (panel step 3)

Folds 2-adversary.md into 1-design.md. Probes: `probes/` (p), `probes-adv/` (a).

## 1. One meaning of plain

**Plain** is CORE §1's kind: copies, owns nothing, views nothing (`Int`, `Bool`, `Static`, enums, `Simd`, function values, objects of plain parts). The compiler has three sets:

| Set | Where | Agrees with CORE §1? |
|---|---|---|
| `Copy + Owned` | `sema.copies`, loan facts | **Yes** |
| `isPlainData` | 11 callers | No: admits `?String`, drops function values |
| The Zig type | emit | No: `?Int`, `?E`, `?Simd`, `?Slot[n]`, `?{A}` look plain (a01, a03, a05) |

**One:** `sema.isPlain(ty)` = `Copy ∧ Owned`, the only fact `$plain` reads; rename `isPlainData` (`holdsNoLoanButText`), unchanged; no Zig type is asked (§3).

## 2. The narrowing

**Where.** `$plain(T)` is an operand of the top-level `and` chain of an `if`'s, a guard's (`stmt if c`), or an `a if c else b`'s condition; `T` is a type parameter or `S.Item`. The region is the block, statement, or `a`, plus later operands. Nothing narrows under `or`, `not`, or parentheses (a08: `($plain(T) or c) and d`), in `else`, for `$plain(P[T])`, or through a function.

**What.** In the region `T` keeps everything it had outside and is also known to copy and to hold no loan. A private `T` stays per-instance (`<`, `+`, `x.m()` pass as outside, a07); a bounded one gains `Copy + Owned` where a bound is met. Narrowing never makes `T` bounded.

**Desugaring.** Plain instances compile `f₁`, `f` with `T` known plain in the region; the others compile `f₀`, each region replaced by its `else`, `b`, or nothing. Requirements recorded in the region (`<`, literal fit, `$size`, nested instances) are checked at `f₁` instances: a plain object without `Ord` under `x < y` is rejected there (a new test).

**Soundness** of escapes (Lists, fields, captures, owned closures, `defer`, `return`, `break`) is unchanged; a04 is sanitizer-clean.

## 3. Who decides (fix 1, HIGH)

**Sema decides, once:** `expandInstantiations`, which makes every concrete instance, stores `plain_bits` (one per tested parameter or `S.Item`, from `sema.isPlain`) on each instance whose body tests `$plain`. Inside a generic body, each site making such an instance gets `plainOf(arg)`: `false`, or the conjunction of the caller's own bits.

**Emit prints, deciding nothing:** a `comptime __rig_plain_T: bool` per tested parameter; `if (__rig_plain_T)`; `and` chains as nested `if`s with the `else` once (labeled block); each site passes sema's expression.

**Effect:** `f[Int]`/`f[?Int]` and `f[Static]`/`f[?String]` split; a02 prints `none`; no guarded call makes an unchecked Zig instance; step 1's decision 2 is gone (`Map[Static, V]` packs); no `rig.isPlain`. Only generics that test `$plain` pay: `Map(K, V, pk, pv)`.

## 4. The oracle (fix 3)

| File | Change |
|---|---|
| `kinds.zig` | narrowed `T` is `.plain`; memo keyed by the narrowed set |
| `lower.zig` | `copiesNoT`, `t_calls` skip regions, so `Map[String, _]` stays checked |
| `lower.zig`, item mode | `itemFinding` skips absent regions |

The compiler's item check skips them too, so the two agree (a05, a07). Gate: corpus abstentions must not rise. ~100 lines.

## 5. The packed Map's fill

```rig
  sub rebuild_packed(!@, n: Int)
    if $plain(K) and $plain(V)
      filler = @es[@at[0]]                # Entry[K, V] copies here
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

## 6. The SPEC paragraph (Generic bodies, after the copy paragraph)

> `$plain(T)` is `true` where `T` is plain data (CORE §1): it copies, owns nothing, and views nothing, as a type that provides both `Copy` and `Owned` does. Each instance answers it when the program compiles. In a generic body, where `$plain(T)` is an operand of the top-level `and` chain of an `if`'s, a guard's, or an `a if c else b`'s condition, and `T` is a type parameter or an associated type, the block, the guarded statement, or `a`, and the operands after the test, are checked with `T` as it is elsewhere, and also known to copy and to hold no loan. Only the instances where `T` is plain compile them, and what they do is checked at those instances alone; in the others they are not there, and the `else`, or `b`, runs. Nothing else narrows: not `or`, `not`, `else`, `$plain(P[T])`, or a function that returns the test.

Beside it: the copy sentence says "must copy: plain data or a read view" (p12, a06); `$plain` joins Builtins.

## 7. Owner decisions (defaults)

1. `$plain`, not `$copies`. Default: yes.
2. Sema's per-instance answer, emitted as a `comptime` Bool; `Static` plain everywhere. Default: yes.
3. "`T` as elsewhere, also known plain", not "bounds added". Default: yes.
4. Only top-level `and` conjuncts; guards and `a if c else b` included. Default: yes.
5. Plain is one fact, `Copy ∧ Owned`; rename `isPlainData`. Default: yes.
6. Fix the copy sentence. Default: yes.
7. Oracle into `lower.zig`, gated on abstentions. Default: yes.
8. No CORE change. Default: none.

## 8. Build size

| File | Work | Lines |
|---|---|---|
| typecheck.zig | `$plain`; conjuncts; regions; notes | ~100 |
| sema.zig | `isPlain`; narrowed set in `copies`, loan facts, bound satisfaction; `blockLive`; `plain_bits`, `plainOf`; guards; rename | ~150 |
| ownership.zig | regions; `addRequirement`; instance and item checks skip absent regions | ~50 |
| emit.zig | comptime parameters; sema's bits at sites; nested `if`s | ~90 |
| test/oracle | kinds.zig and lower.zig (§4) | ~100 |
| SPEC, tests | paragraph; examples p01, p05, p08, a08; p01-p11, a01-a08 under the sanitizer; a live-instance rejection | ~300 |

About 490 lines of compiler and oracle, plus tests.
