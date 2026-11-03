# Beat tsrs: shared brief for both committees

Owner, 2026-10-24: "I believe we will find a major breakthrough on this. Each of those numbers reveal special actions occuring in tsrs under the hood. We need to identify those and see how we can mirror them or beat them." Earlier: "Study the journals, online research, work done by others ... Think outside of the box. Review other fast tools. Think of ways to remove extra checking, while still informing LLVM ... There is no reason for us to not be the fastest code we can find."

## The measured gap (pup, ts-pattern, check mode)
- **Time:** Trig 1.164 s at one checker against tsrs's 0.661 s on one thread (1.76×); every core, 0.496 s against 0.223 s (2.22×). Scaling from one to all cores: 2.35× against 2.96×.
- **Instructions:** 13.22G against 8.14G, tsrs being the same-version source build without PGO. Trig's types and instantiations counts equal tsc's, so the gap is cost per operation.
- **By family (self instructions; perf record -e cpu_core/instructions/u, one checker on core 3; each symbol put in one family by name):**

| family | trig | tsrs | extra | ratio |
|---|---|---|---|---|
| instantiation + mapper | 3083M | 2030M | +1053M | 1.5 |
| maps (Map/Set vs PackedMap, SymbolMap, Relation, hashbrown) | 1875M | 842M | +1032M | 2.2 |
| member listing + sort | 936M | 340M | +596M | 2.8 |
| alloc + copies | 859M | 344M | +516M | 2.5 |
| relations | 1081M | 606M | +475M | 1.8 |
| members + symbols | 1454M | 1083M | +371M | 1.3 |
| conditional + flow | 562M | 434M | +128M | 1.3 |
| parse + bind | 151M | 97M | +54M | 1.6 |
| rest | 2208M | 1740M | +468M | 1.3 |

- **Details:**
  - Trig Map self 1560M + Set 126M; tsrs hashbrown insert 333M + search 192M + reserve_rehash 91M.
  - rig.alloc.alloc 290M, free 205M, heap 59M; ListOf push/grow 288M; memcpyFast 108M. tsrs: mimalloc about 2.5%, memmove 0.5%.
  - instantiate_type_with_alias 984M vs tsrs's worker 861M; mapper_map 657M vs TypeMapper::map 562M; get_object_type_instantiation 476M (inlined into the worker in tsrs), get_type_items_instantiation_key 137M, instantiate_types 123M, instantiate_symbol 157M.
  - Member listing: compare_symbols 350M, is_declaration_contained_by 303M, Checker.text 130M, the sort 130M.
- **With every Rig safety check removed,** ts-pattern runs 11.2% faster (records 2026-10/safety-checks/measurement.md).

## Where things are (read-only)
- **tsrs source:** pup:/zfs/trig-pup/tsrs/src (Cargo workspace). Shipped binary: pup:/zfs/trig-pup/tsrs-shipped/package/tsrs.
- **Profiles:** pup:/zfs/trig-pup/trial/ins/{t.data (Trig), r.data (tsrs), tg.data (Trig, frame pointers)}, with text reports t.txt and r.txt. You may run `perf report`/`perf annotate` on these files; **don't start new timed or all-core runs on pup** (others are timing; Trig's timing cores are 3 and 4).
- **Notes by Trig (fork):** /private/tmp/claude-501/-Users-shreeve-Data-Claude-Worktrees-trig-trusting-grothendieck-215136/e9ff8838-bebc-4a05-b45d-83dcc07d0404/scratchpad/{tsrs-review-cpu.md, tsrs-review-mem.md, pr199.md, bench-fair.txt}.
- **Trig source:** ~/Data/Code/trig/src (Rig). Rig source: ~/Data/Code/rig (main; read-only), with std/__rig_builtin.rig (Map/Set), src/alloc.zig (allocator), src/runtime.zig, src/sched.zig, src/emit.zig and src/proofs.zig. Rig's emitted Zig for any Trig module: `bin/rig emit FILE` from its directory, or a build's RIG_OUT_DIR package.
- **Running in parallel (don't duplicate):** a scaling investigation (oversubscription, the pool, E-cores, contention); a Map/Set industry survey (SwissTable, hashbrown, F14, Go Swiss, indexmap); a proving-checks research (BCE); and RIG_MAP_TRACE (real op streams coming). Use their findings where they reach you.

## Rules
- Rig's North Star: no unproven "trust me" hints (UB if wrong), the owner declined those; emit decides nothing; one classifier per fact.
- Vocabulary: lend/view/loan, never "borrow"; `obj` is an "object".
- Each recommendation needs evidence (a tsrs source file:line, a profile line, a measurement, or a primary source), an estimated win in instructions or time on ts-pattern, a Rig-side or Trig-side owner, and its cost.
- Write ≤500 words to your file beside this brief, and reply with a ≤120-word summary.
