# Cap the package cache by size (branch cache-cap)

Problem: the cache home grew to 248 GB; the trim limited only by age.

- RIG_CACHE_MAX_GB (default 10, 0 = none, decimals ok). Over it, the trim removes least recently used packages (dir mtime) until it fits, after the 5-day age pass.
- Cheap size: each build records `<pkg>/.size` (walks one package) and moves `<home>/.usage` by the delta. A run reads `.usage`; over (or missing) -> trim allowed every 10 min instead of daily. The trim measures packages lacking .size in memory (never writes into a package it does not hold: that would reset its age) and rewrites `.usage`.
- Safety unchanged: tagged home, rig-made entries only, skip locked, re-check under exclusive lock (LRU requires the mtime unchanged), rename-then-delete, never RIG_OUT_DIR; `.usage` is a rig-made entry for clean/tagging.
- Litter: test/run, matrix.py, equiv.py already set RIG_OUT_DIR/store for every run/build; test/hints.py did not: fixed.
- Docs: --help, README, INTERNALS, test/README.
- Test: test/cli/cache_trim.sh (oldest first, locked kept, estimate == measured sum, rate limit, cap 0, RIG_OUT_DIR). Gates: zig build, ./test/run --delta: 3177 passed, 0 failed.
