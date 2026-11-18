# Free fork-join: where the time goes, `par`, and the bar (expert 3)

Mac M5, 7a2efd0f3 `--release`, fastest of 12 to 16 rounds, interleaved. Boards: [measurement/](measurement/); checks: [concurrency-checks-cost](../concurrency-checks-cost/README.md).

**psum.** First call 2.42 against 2.06 ms; third call 1.98 against 1.92 (3%); plain loop 5.19 against 5.12. So 83% of the gap is the first parallel call: 0.44 ms over a warm call, against Rayon's 0.14. Forks, parks, stealing and the loop together cost at most 3%.

**qsort, like for like.** Rig 72.5 ms, Rayon 51.8:
- Rayon with std.sort's algorithm ported (SymMerge, direct compare): 58.0. The leaf algorithm is 30% of the gap.
- Rig with that sort in the program, compare direct: 63.7. std.sort's indirect compare is 43%.
- The residual is 27% (Rig 9.8% slower). At the top level alone, element appends against `extend_from_slice` cost 2.5 ms and the partition 0.9. Fork-join and checks together are at most about 2.3 ms (4%).
- The checks' 17% sat in std.sort's indirect path, so little of it survives.
- Leaves sorted once, sequentially: std.sort 265 ms, `sort_unstable` 26.6.

**`par` splits by what is left.** `par.map` and `par.each` recurse on `lo..hi`: fork the left half with `&` and run the right, while `splits > 0` or the task was stolen. `splits` starts at the workers running (or `limit:`) and halves at each split. A steal resets it to `max(workers, splits/2)`, as Rayon's `Splitter` does. A failure stops further splits. No shared counter; a nested `par` costs only unstolen forks. It needs: free fork-join, a `stolen` bit, and thieves taking the oldest fork.

**runtime.md.** I agree that forks are not the gap; warm psum bounds forks and parks at 3%. But the ramp is the first call's start-up, and about 70% of qsort's gap is std.sort.

**Defaults, by measured share**
1. `bench/fork`'s qsort like for like: one leaf algorithm on both sides.
2. std.sort compares through a generic, inlined (43%), and gains an unstable sort (30%); the name is the owner's call.
3. Trace psum's first call (83% of its gap) before changing how workers start.
4. A List append from a slice, as one copy.
5. Free fork-join pays off in `par`'s adaptive splitting and in nested `par`, not in psum or qsort.
6. `bench/fork` against Rayon, Mac and pup: psum cold and warm, matched qsort, a GRAIN-256 tree sum, skewed and nested `par.map`. Bar: warm rows within 2%; bench/tasks, actors, net, http, par-push, Trig and the guards no slower.
