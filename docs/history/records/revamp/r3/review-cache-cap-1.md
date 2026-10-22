# Review: cache-cap (src/main.zig, test/) -- can it delete/rename/modify what rig did not create, or a package in use?

Built origin/cache-cap in a detached worktree; all tests in scratchpad temp dirs (HOME, XDG_CACHE_HOME inside it). Worktree removed.

## Verdict
No deletion of a foreign package or a locked package found. Two findings of "modifies something rig did not create" (A, B-minor) and one crash (C). Fix A and C before merge.

## Findings

### A. (should fix) The trim overwrites any `.usage`, even one rig did not make -- CONFIRMED
`trimCache` ends with `writeNumber(home/.usage, total)` whenever cap > 0, unconditionally.
`CacheEntry.of` only calls `.usage` rig-made when it is a regular file of <= 32 bytes, and the trim/clean loops skip anything else as foreign, yet the write replaces it anyway.
Tested in a tagged home:
- a 55-byte foreign `.usage` file: replaced by "5968234\n".
- a symlink `.usage` -> victim: the link itself is replaced by a regular file (victim content untouched; link destroyed).
`recordSize` is also not gated on a tagged home: in an untagged home (foreign contents, tag refused) it overwrites a `.usage` that holds a number (<= 32 bytes parseable as u64). The `<pkg>/.size` write is inside a rig-made package dir, fine.
Fix: before writing, require `CacheEntry.of(d, io, ".usage", .file) == .usage` or absent (lstat; not a symlink, size <= 32), and gate `recordSize`'s `.usage` update on the home being tagged (isTag). Add a cli test: foreign/symlink `.usage` survives a trim.
Weak identification (same as the existing `.trimmed` rule, size-based only): `rig clean` deletes any <= 32-byte regular `.usage` in a tagged home. Acceptable; note it.

### B. Other deletion/rename/write paths -- no problem found
- Package removal still goes through removeEntry: exclusive try-lock (locked package => busy, kept), inode re-check, rename-then-delete, tagged home only. The cap pass adds `.unchanged`: requires the dir mtime equal to the scan value read under the lock, so a package used or re-created since the scan is kept. Null mtime => kept.
- `current` is never evicted. Only `.package`-kind entries enter the cap pass (trash/stamp/tag/usage are never LRU candidates). RIG_OUT_DIR / RIG_BUILD_STORE: home is null, no new code runs (recordSize/trim are `if (home)`).
- `.size` writes happen only after the run/build, in the package the process holds under a shared lock, and are skipped when unchanged. The trim never writes into a package (measures in memory). Symlinked `.size` is read with nofollow (ELOOP -> null) and replaced by atomic rename, never followed.
- treeSize does not follow links and caps depth at 64; reads only.
- mtime ties: unstable sort, arbitrary but safe. Future mtime: the package sorts last and is never evicted (also "fresh" for the age pass), so the cap may stay unmet; safe.
- `.usage` race: read-modify-write by parallel runs loses updates; trim also overwrites it. Drift is saturating (no underflow) and bounded: the daily trim (or over-cap 10-min trim) re-measures. Under-estimate delays trimming up to a day; harmless to safety.
- Thrash: stamp limits trims to one per 10 min while over. A run not yet holding its lock (before holdPackage) can have its LRU package evicted; it then recreates and rebuilds (cost only, no corruption). If the working set exceeds the cap, every 10 min all non-current unlocked packages go -- inherent to a too-small cap, not a bug. A burst does not repeatedly trim (stamp is taken before the scan).
- RIG_CACHE_MAX_GB: tested abc, -5, nan, inf, "", 1e400 -> default 10 GB (nothing removed); 0 -> no limit; 1e-12 -> truncates to 0 = no limit (surprising but safe); 0x1p-30 and 0.0000001 evict as expected. Hex-float input is accepted (harmless).

### C. (should fix) Integer overflow panic in the trim on a corrupt `.size` -- CONFIRMED
`total += item.size` (u64, plain add). Two packages with `.size` = 18446744073709551615 => "panic: integer overflow", rig exits in the middle of an ordinary `rig run`. The stamp is touched first and `.usage` is never written, so the next trim 10 min later panics again: a build fails once per 10 minutes until someone removes the bad `.size`. Needs a corrupted/foreign `.size` (rig writes only real sizes), so low likelihood, but a corrupt cache file must not crash a build. Same for `total` in the age pass (it uses `-|=`, fine).
Fix: `total +|= item.size`; optionally treat a `.size` above some sane bound as unrecorded and measure it.
Related, no crash: a huge `.size`/`.usage` makes the cache look over cap, so LRU eviction of unlocked non-current packages until the sum fits (corrupt `.size` => evicts everything unlocked). Rig-made packages only; consider ignoring a `.size` larger than the measured tree.

### D. Minor
- Atomic temp file for `.usage`/`.size` (createFileAtomic) on macOS is a named temp in the home/package; a kill in the window leaves a stray file in the home that rig does not recognize (blocks `rig clean` removing the home dir). Same pattern as writeTag; not new in kind.
- The test (test/cli/cache_trim.sh) has no case for a foreign/symlinked `.usage` or an overflowing `.size`; add both with A and C.
