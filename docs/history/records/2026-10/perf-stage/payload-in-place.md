# A payload taken out of an optional, copied once (2026-10-28)

**The question.** [memory-traffic.md](memory-traffic.md) found Trig's
288-byte `Relater` copied whole several times each time it left its
pool, `(!@free_relaters).pop() ?? Relater()`, the largest single source
of loads blocked by store forwarding. Its ceiling arm 4, a hand edit of
Trig's emitted Zig, measured 28-36% fewer blocked loads and 2.0% fewer
user cycles on ts-pattern. The owner approved making emit write that
code itself, for the whole class (2026-10-28).

**The answer.** The class is a payload taken out of an optional by
value. Emit wrote `rig.some(o) orelse d`, and `pop` built its optional
from the element: the element is copied into a Zig `?T`, into the
optional's bytes, into a `?T` again by `unwrap`, and into the result,
four copies of 352 bytes in the reproduction below. `rig.rt` and
`rig.take` cost no copy: LLVM already passes the value where it lies,
in the reproduction and in Trig's binary alike. Emit now copies the
payload once:

| Rig | Emitted |
|---|---|
| `xs.pop() ?? d` | `(if (xs.popAt()) \|p\| p.* else d)` |
| `if xs.pop() as v`, `while xs.pop() as v` | `if (xs.popAt()) \|p\| { var v = p.*; ... }` |
| `o ?? d`, `o` made here or a place | `(if (rig.somePtr(&o)) \|p\| p.* else d)` |

On Trig, release, 20 interleaved rounds on pup's core 3: loads blocked
by store forwarding 17.8% fewer on ts-pattern and 26.5% fewer on zod3,
and `check_type_related_to_ex_output`, which held 9.6% of them, leaves
the profile. User cycles are unchanged on ts-pattern (0.0%) and 0.4%
fewer on zod3; instructions, faults and peak memory are the same. The
ceiling's 2.0% did not reproduce either: its own binary, run again
today (12 rounds), gives 4.9M fewer blocked loads and cycles within
0.7% either way. The stalls overlap other work. The change is under
the speed bar, and waits as a draft to be measured stacked with
others.

## The reproduction

[pool.rig](payload-in-place-data/pool.rig) is Trig's pool in small: a
`List` of 352-byte objects, popped with `?? Big()`, changed, cleared
and pushed back. Its package was built `--release` with `work` made
`noinline`, and each form of the pop written into its Zig by hand
([variants.py](payload-in-place-data/variants.py)), then built for x86
(`-OReleaseSafe -mcpu=meteorlake`) and for the Mac:

| `get`'s body | x86 vector moves in `work` | memcpy calls | arm64 frame |
|---|---:|---:|---:|
| main: `rig.some(xs.pop()) orelse Big{}` | 52 | 4 | 1,440 B |
| no `rig.rt` on the caller's `var` | 52 | 4 | 1,440 B |
| pop's optional written once (`packSome`) | 52 | 4 | 1,440 B |
| `if (rig.somePtr(&tmp)) \|p\| p.* else Big{}` | 28 | 2 | 720 B |
| `if (xs.popAt()) \|p\| p.* else Big{}` | 22 | 2 | 720 B |
| the ceiling's hand edit | 22 | 2 | 720 B |

`rig.rt`, `rig.take` and the push side change nothing: what costs is
the optional. A 56-byte object shows the same, 23 vector moves to 12,
so the rule needs no size: every payload held whole in memory (an
object, an array, a String) is taken by address.

In Trig's binary, `check_type_related_to_ex_output` (where
`get_relater` and `put_relater` inline) has 83 vector moves on main and
19 with the change, and its frame falls from 1,608 to 984 bytes.

## What was built

- `storage.takeFrom`, a recorded decision (`sema.Question.take_from`)
  of each `??` and `as` condition: `.slot` for `xs.pop()` of a List
  held where it is, `.held` for an optional made here that no slot keeps
  or a place that is no move, `.value` for the rest (a fallback that is
  itself optional, a payload copied out of a view, a scalar payload).
  The storage plan records the capture (`leaf`, or `as_value` as a
  pointer) and the Zig temporary of a made optional (`zig_temp`).
- `List.popAt`, in the runtime: the last element's address in the slot
  it leaves. The copy out happens before anything can change the List.
- Moves and drops are as they were: the payload is copied out whole,
  where it was copied by value before, and the ownership checker and
  the oracle walk the same program. An `as` binding owns the element to
  the end of its body, and `as _` drops it at once, as before.

## Measurement

- **Builds** ([setup.sh](payload-in-place-data/setup.sh)): Rig main
  `373b6aed3` and the branch (`256a070d7`), built on pup's E-cores
  12-15; Trig `403a823` built `--release` by each through
  `/zfs/trig-pup/trial/slot.sh` on slot 10,11.
- **Timing** ([time.sh](payload-in-place-data/time.sh)): core 3,
  sibling 4 idle, interleaved, 20 rounds, one checker; `perf stat` of
  user and kernel cycles, user instructions,
  `ld_blocks.store_forward`, and faults; wall and peak memory from
  `/usr/bin/time`. Every run's output was identical to main's. Raw lines
  in [time-raw.log](payload-in-place-data/time-raw.log), summarized by
  [tsum.py](payload-in-place-data/tsum.py):

| ts-pattern | main | branch | branch against main |
|---|---:|---:|---|
| user cycles | 3,969.9M | 3,968.0M | 0.0% fewer |
| kernel cycles | 333.3M | 332.1M | 0.4% fewer |
| instructions | 9,270.6M | 9,269.1M | 0.0% fewer |
| blocked loads | 13.66M | 11.22M | **17.8% fewer** |
| faults | 40,160 | 40,151 | same |
| wall | 0.90 s | 0.90 s | same |
| peak RSS | 266.6 MB | 266.5 MB | same |

| zod3 | main | branch | branch against main |
|---|---:|---:|---|
| user cycles | 734.1M | 731.3M | 0.4% fewer |
| kernel cycles | 92.8M | 92.7M | 0.1% fewer |
| instructions | 1,683.7M | 1,683.5M | 0.0% fewer |
| blocked loads | 2.94M | 2.16M | **26.5% fewer** |
| faults | 9,765 | 9,750 | same |
| wall | 0.18 s | 0.18 s | same |
| peak RSS | 86.0 MB | 85.9 MB | same |

- **The ceiling again** ([ceiling-raw.log](payload-in-place-data/ceiling-raw.log)):
  memory-traffic's one binary (`packs/x`, Rig `4d80efe17`), `RIG_X=0`
  against `RIG_X=4`, 12 interleaved rounds on core 3: blocked loads
  17.56M and 12.67M, user cycles 0.7% more by the median and 0.2% fewer
  by the fastest run.
- **Where the blocked loads are now** (`perf record -e
  ld_blocks.store_forward`): the Map's tag load in `is_type_related_to`
  and Trig's own functions (`instantiate_type_worker`,
  `get_implied_constraint`, ...), none of them a copy of a pooled value.
- **std.json and the Map guard** (Mac): every row within 1% of its
  baseline, all fewer instructions on std.json.
