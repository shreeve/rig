# Review: REVAMP-3 step 6, result origins (`r3-step6` at `24b9759b`)

I reviewed this independently and wrote none of the code. I used the
worktree's `bin/rig` and `bin/rig-oracle` (built at `24b9759b`) and
compared with `rig-6-base`, plus `rig-v014`, `rig-hf5`, `rig-3s-base`
and `rig-45-base` to date the pre-existing findings. Every probe ran
with `RIG_SANITIZE=1 bin/rig run`. I ran no suites and changed nothing in
the worktree.

Probes are in `.git/revamp/r3/probes/review-step6/`, one file per probe,
each with a header comment. Multi-module probes are directories (`m1_`
to `m5_`, `map8_`, `pos/p2_cross`). Positive probes (programs step 6
should accept) are in `pos/`. `HEAD-results.txt` holds every probe's
verdict at HEAD (154 programs). `run.sh` runs one probe on the new
binary, the base, and the oracle.

## Verdict

**I found no unsoundness in step 6.** None of my probes in any of the
six sub-features gets an accepted program that corrupts memory, leaks,
gives a wrong result, or fails in Zig. The oracle agreed with the
compiler on every step-6 probe. Its only disagreements are the two
pre-existing holes below (C1, H1). Neither is caused by step 6, and
neither is a soundness round against it.

| # | Sev | Sub-feature | New? | Finding |
|---|---|---|---|---|
| C1 | **Critical** | none (lend table / `walkElems`) | **pre-existing on revamp** (present in `rig-3s-base`, `rig-45-base`, `rig-6-base`; `main`, v0.1.4 and hotfix #5 reject the slice) | `?h[..]` of a `*Text` makes a String that carries **no loan**. Dropping or replacing the handle frees the bytes: use of freed memory. |
| H1 | **High** | none (generic emit) | pre-existing (v0.1.4 too) | A generic type's method `left(?self, other: ?T) -> ?T` instantiated at `Int` and called with `?o` emits `p.left(o)` where Zig wants `*const i64`. The Zig does not compile. |
| M1 | Medium | 1c `from` (scope) | new gap | std has no `from` clauses. The design's flagship programs stay rejected: synthesis §3.2 example 1 (`strip_prefix` in a loop), `strip`, `cut`, and `f8` (`os.env from static`). |
| L1 | Low | grammar / 1c diagnostics | new | A parameter named `static` cannot be named in `from`: `from static` always means "the whole program". The help line then suggests the clause already written. `from b, static` says "`f` has no parameter `static`; `from` names parameters, `self`, or `static`", which contradicts itself. |
| L2 | Low | 1b reach | new | With targets `any` (a type-variable or callable result), `reachTargets` never counts a by-value `String` parameter. I could not make this unsound, because a generic or callable body cannot turn a String into a `T` or a callable. At worst it is a callee-side false rejection. |

### C1: a slice of a `*Text` lends nothing (Critical, pre-existing on revamp)

Probes:
- `h5_shared_text_local.rig` (local handle);
- `h3_shared_text_string.rig` (by-value `*Text` parameter returned from a function);
- `h10_shared_text_field_slice.rig` (a `*Text` struct field, with the struct replaced).

```rig
sub main
  h = *Text("hello")
  s = ?h[..]
  -h
  print(s)
```

```
error: rig: use of freed memory at address 0x78c000bf77
Bus error at address 0x78c000bf77
compiler_rt/memcpy.zig:162:17: ... in copyFixedLength (compiler_rt)
```

The oracle rejects each one:
- h5: `DIFF ... main prod=accept ref=reject C4 5:3 cannot move h while a read loan of it is live`;
- h3: `DIFF ... peek prod=accept ref=reject C5`.

`rig-6-base`, `rig-45-base`, `rig-3s-base` and `rig-10e-base` all crash
the same way. `rig-hf5`, `rig-base`, `rig-a0` and v0.1.4 reject
`cannot slice a value of type *Text`. So the revamp made the slice legal
before step 3, and step 6 did not cause it.

**Root cause.** Typecheck accepts slicing a `*Text`. The ownership
checker's `walkElems` recognizes only an array, a Vec, a write slice, or
`isText(peeled)`:
- `isText` matches `Text` and `Box[Text]` (`boxedType`), not `*Text`;
- `pointee` peels only `?`/`!`.

So the slice falls to `walkOperand`. That is a plain read of `h`, which
holds no loans, so the String carries nothing. The implicit lend of the
same handle as a String (`id(?h)`, `h7_shared_text_lend_as_string.rig`)
is correctly rejected, through `walkImplicitLend`.

**Class.** "Is this a lend of a Text's bytes" is decided twice: once by
typecheck (what may be sliced) and once by ownership (`walkElems`'s
type test), and they disagree on a handle. That breaks AGENTS's "one
classifier per fact".

**Siblings checked.** These are rejected by typecheck (no slice of a handle):
- `*Vec[Int]` (h4);
- `*[4]Int` (h9).

These are correctly lent:
- `Box[Text]` (h8);
- `?h.t[..]` of a by-value `*W` parameter (h6);
- the implicit `?h` (h7).

The bug is reachable wherever a `*Text` is sliced: a local, a by-value
parameter, or a field.

### H1: generic `?T` method at a scalar fails in Zig (High, pre-existing)

Probes:
- `z2_generic_method_ret_readview_int.rig`;
- `pos/p3_generic_from.rig`, where I found it.

```rig
struct Pair[T]
  x: T

  fun left(?self, other: ?T) -> ?T
    ?self.x

sub main
  p = Pair(x: 5)
  q = ?p.x
  o = 6
  q = p.left(?o)
  print(q)
```

```
__rig_main.zig:26:15: error: expected type '*const i64', found 'i64'
    q = p.left(o);
```

The new binary, `rig-6-base` and v0.1.4 all fail the same way. It needs
the `?T` result: the same method returning `Int` runs (`z1`). It is
unrelated to `from`.

### M1: std writes no `from` (Medium, scope)

Synthesis §6 row 1c lists "std's three `from s` (`strip_prefix`,
`strip_suffix`, `cut`) and `os.env`'s `from static`". The implementer
notes "No from needed in std/tests". As a result, these are still
rejected:
- `origins/probes-fit/f1_prefix_loop.rig` ("`key` does not live long enough");
- `f1b_prefix_tmp`;
- `probes-formal/strip.rig` and `cut.rig`;
- `f8_env_static.rig`.

`pos/p5_user_strip_prefix_from.rig` copies `strip_prefix` with `from s`,
and the flagship loop then runs clean (`["ada"]`). So the feature works,
and only std is missing the clauses. The bodies satisfy them:
`strip_prefix` and `strip_suffix` slice `s`, and `cut` builds a `Cut`
from slices of `s`. This is a design-intended acceptance, not a
soundness issue.

### L1 and L2

- `gr2_from_static_param_named_static.rig` and
  `gr12_from_static_in_list.rig` show the confusing diagnostics.
  `gr7_from_duplicate.rig` (`from a, a`) is accepted silently, which is
  harmless.
- L2 is reasoned in `sema.ReachWalk.step`, with `g7` showing `result:0`
  for `pick[T](a: ?T, s: String) -> ?T`. The `.string` case reaches
  only when `targets.bytes`, and the `any` branch uses `path.viewed`,
  which is false for a top-level by-value parameter.

## What I attacked, by sub-feature

Every program listed here is **rejected** at HEAD (or runs correctly
where it should), so nothing below is a finding.

### 1a mapping (CallParams)

- **UFCS with the receiver first:** `Cur.pick(?c, ?a)` with `from x` and
  with `from self` (`map1`, `map2`).
- **Defaults and keywords:** a defaulted parameter left out before a
  keyword argument (`map3`, `map6`).
- **Generic methods:** compile-time arguments with the receiver first
  (`map4`).
- **Write-receiver stores:** a write-receiver method storing an argument,
  called with reversed keyword arguments (`map5`).
- **Aliases:** an associated function through a type alias (`map7`).
- **Across modules:** a method and a function with keywords (`map8`).
- **Positive mapping:** `pos/p1` and `pos/p2_cross` run clean, so the
  masks map exactly and are not merely conservative.

### 1b reach default

- **Generics:**
  - a generic type without methods holding views, as a holder and as a
    store target (`g4`, `g5`, `g8`, `g9`);
  - T6 holds: a view T, or a T holding a view, is rejected for generic
    functions and for generic types with methods (`g1`, `g2`, `t4e`);
  - String as T is allowed (`g6`) and stays sound, because a type
    variable reaches everything.
- **Modules:**
  - a transitive type main never imports (`m1`);
  - an imported generic instance's non-T fields: an owned Vec, a Text,
    and a third-module struct (`m2`, `m3`, `m4`);
  - builtin `Vec` atoms across modules (`m5`). Builtins are registered
    first in every module, so their symbol ids agree.
- **Box, handles, optionals:**
  - Box cannot hold views;
  - methods through Box and `*T` receivers (`bx1` to `bx3`);
  - `*N` holding a String, cloned (`str3`);
  - `Box[String]` (`str2`);
  - by-value handle parameters (`h1`, `h2`, `h6`).
- **Vecs and arrays of views:**
  - `Vec[?Item]` and `Vec[Ref]` copied out through a read view (`na4`,
    `na5`, `pos/p4`);
  - `copy` and `fill` of views (`el1`, `el2`, rejected by typecheck);
  - `insert` (`el3`).
- **Structs holding views:**
  - a cursor through a `for`/`if as`/`match` binding, a made header
    subject, a made Vec (`tv1` to `tv5`, `hd1` to `hd3`);
  - after a store through a local write view, a call, or a held write
    view (`wv1` to `wv3`).
- **View of a slice:** `?[]Int` keeps the loan on the slice place
  (`vs1`, `vs3`). It cannot be built from a non-place (`vs2`, `vs4`).
- **Bytes class:** a Text or a String cannot become a `[]U8` in safe code
  (`b1`, `b2`).
- **Emit agrees with the desugaring:** lends through read-view fields
  (`?c.items`, `?c.s[1..]`, `?c.name`, `?c.items[..]`, `?c.one`)
  survive replacing and dropping the holder, sanitizer-clean (`em1`,
  `em2`).
- **The private-field hazard:** a cursor that also owns Items stays lent
  (`na3`).
- **Re-run of the newly accepted programs:**
  - all 19 newly accepted corpus programs, and the 11 origins probes
    that went from rejected to accepted, run sanitizer-clean;
  - nastier variants are rejected: the parser cursor with the owner grown
    (`na1`), and a key of the result's own type (`na2`).

### Store narrowing (T4)

**Stores through a capture are rejected in every form:**

| Form | Probe |
|---|---|
| direct push | `t4a` |
| a helper | `t4b` |
| a field | `t4c` |
| a generic helper | `t4e` |
| a method | `t4f` |
| a struct parameter | `t4g` |
| a String parameter | `t4h` |
| a nested closure | `t4j` |
| a moved write view `<w` | `t4o` |
| through a `?fun` with a callee-local argument | `t4q` |
| into a Cell, including from an owned closure | `t4n`, `t4t` |

**Other channels are closed:**
- Re-pointing a captured read view, `replace`, and writing through a
  read capture's `!` field are rejected (`t4d`, `t4i`, `t4p`).
- Owned and moved captures are fixed (`t4k`, `t4l`, `t4m`).
- A closure cannot store its capture in its own write parameter, whether
  called directly or through a `?fun` (`cl1` to `cl3`).
- A lent callable counts as a store source and a result source (`t4r`,
  `t4s`).
- Nested fields with an enum payload, and replacing a handle in a write
  parameter (`st1`, `st2`).
- Self-loans through `!self` and `!h` are rejected (`s1`, `s2`), and so
  are two-parameter cross stores (`s3`).
- `swap` refuses view holders (T5, `sw1`, `sw2`).

### 1c `from`

**Violations found by the body check:**
- branch, `??`, `catch`, a loop with a defer, recursion, and mutual
  recursion (`f4` to `f9`);
- a Vec local, `while as`, `raw`, `?`, a moved local, an if-value, and a
  fallible result (`f10`, `f11`);
- re-pointing `self.items` then returning through self (`f3`);
- by-value view holders with `from static` or `from d` (`f1`, `f2`);
- a generic function and a generic type's method (`fv4`, `fv5`);
- a returned `?fun` call (`fv2`);
- `from static` with a branch returning the parameter (`fs1`).

**Function values fall back to the default.** This holds for a
reassigned local, a `?fun` parameter, and an `if`-chosen callee (`fv1`
to `fv3`).

**Positive cases run:** `from static` with literals, a module constant,
and `os.args` (`pos/p6`), and generic `from` (`pos/p3`, apart from H1).

**Extern trust is intact:**
- only std may declare `extern zig`, and no std extern uses `from`;
- `os.env` keeps its default, which carries `name`;
- every other Zig-backed function returns numbers, `Bool` or `void`;
- a C `extern` with `from` is rejected because `I32` views nothing
  (`gr11`).

### receiverLeaves

These are rejected:
- a nested field of a branching value (`rl3`);
- an element of a branching Vec, then the Vec grown (`rl6`);
- a made value's field element (`rl7`).

The receiver-stored-in-argument class, which hotfix #5 also fixes, is
rejected for every receiver shape (`rs1` to `rs8`):
- branching;
- made;
- Box;
- `*T`;
- a read-view local;
- a Vec element, with `clear`;
- a write receiver;
- UFCS.

`o?.method()` runs correctly (`rl4`).

### Grammar

These all mean what they say:
- `from` and `static` as fields, parameters, locals, and a function name;
- `from from`, naming a parameter called `from`;
- a header split over lines;
- `from` as a compile-time parameter name inside brackets;
- `from` on the next line (a local).

These are rejected:
- `from` on a `sub`, on a function type, and on a closure's type;
- `from a.x` and `from (a)`;
- `from n` naming a compile-time parameter;
- `from self` on a free function.

## Classification for the stop rule

| Sub-feature | Soundness findings |
|---|---|
| 1a mapping | none |
| 1b reach default | none (L2 is a false-rejection edge only) |
| store narrowing (T4, T6, extern trust) | none |
| 1c `from` | none (M1 is scope, L1 diagnostics) |
| receiverLeaves | none |
| grammar | none (L1) |

C1 and H1 belong to no step-6 sub-feature, and both are reproduced on
`rig-6-base`. C1 should go to the lead as its own revamp fix: it is a
live use of freed memory on the revamp branch, though not on `main`.
