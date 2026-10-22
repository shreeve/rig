# Review: PR #95 `polish` (head 48b6db55), round 3: locks, tag, recognizer

Scope: `git diff ac9dcd8a 48b6db55 -- src/main.zig test/cli/ test/run`
(c2ec7d54 and the store-days change in 48b6db55).

I built 48b6db55 in a detached scratch worktree (since removed). Every
probe ran with HOME, XDG_CACHE_HOME and ZIG_GLOBAL_CACHE_DIR inside the
scratch directory. I ran `cli/cache_trim` and `cli/test_prune` through
`./test/run` with RIG_BUILD_STORE, RIG_TEST_OUT and RIG_RESULTS_CACHE in
scratch too, and both pass. For lock faults I used a `flock` interposer
(DYLD_INSERT_LIBRARIES, active only in the `rig` process, not in `zig`).
It injects ENOTSUP, ENOLCK, or the NFS access-mode rule.

**Grades.** P1: fix before landing. P2: should fix this round. P3: polish.

## Verdict

**User data is safe.** Rig deletes or renames nothing it did not make,
apart from one contrived case (N2). The locks hold for the whole
write-build-run, and are released on every exit. Removal fails safe when
locks are unsupported or the lock manager is down. There is no deadlock.
R1 and R2 from round 2 are fixed: 120 concurrent runs after an idle week
and 40 runs racing a continuous `rig clean` loop all passed.

**One P1 before landing (N1), a two-flag fix:** on a filesystem that
emulates `flock` with POSIX locks (Linux NFS), a Debug build of rig
panics. A Debug build is what the README's `zig build -p ~/.local`
installs.

## N1 (P1). Lock-file open modes make Debug rig panic on Linux NFS

- `holdPackage` opens `.lock` with `createFile(..., .{ .truncate = false })`,
  which is write-only. lsof confirms it shows as `3w`. It then takes
  `LOCK_SH` on it.
- `lockForRemoval` opens `.lock` with `openFile(...)`, which is read-only,
  and takes `LOCK_EX`.
- flock(2) says this about Linux NFS: "in order to place an exclusive
  lock, the file must be opened for writing". The NFSv4 client
  (`nfs4_proc_lock`) also refuses `F_RDLCK` on a write-only file. Both
  fail with EBADF.
- Zig maps EBADF to `errnoBug`, which panics when `builtin.mode == .debug`.
- Reproduced with the interposer applying that rule (`FLOCK_MODE=nfs`):
  - `rig run hello.rig` gives `panic: programmer bug caused syscall
    error: BADF` in `holdPackage` (main.zig:874), with rc 134.
  - `rig clean` panics in `lockForRemoval`.
- In a release build the error is `Unexpected`. The run then goes on
  unlocked, and the trim counts the package as busy. That is safe, but
  the cache is then never trimmed on NFS.

Fix:
- Open the lock file read-write in both places:
  `createFile(io, path, .{ .read = true, .truncate = false })` and
  `pd.openFile(io, package_lock, .{ .mode = .read_write, .follow_symlinks = false })`.
- Optionally, add a unit or CLI test that locks `.lock` through the same
  open calls.

## Q1. Deletions, renames, creations (every call re-read)

| Site | Effect | Guard | Verdict |
|---|---|---|---|
| `tagCacheHome` (home missing) | `createDirPath(home)`, then `CACHEDIR.TAG` | stat said missing | ok. A tiny race tags a dir a user makes at the same instant |
| `tagCacheHome` (home exists) | writes `CACHEDIR.TAG` (`createFileAtomic`, `replace = false`, so never overwrites) | a directory, not a link, untagged, every entry `CacheEntry.of` != null | **N2**: an empty dir, or one holding only `.trash-<hex>` dirs, counts as rig's |
| `writeTag` | a temp file in home, linked to the tag | `defer deinit` | a crash leaves a stray temp file, which is safe (home is then "others") |
| `holdPackage` | `createDirPath(dir)`, `createFile(dir/.lock)`, `setTimestampsNow(dir)` | `dir` is `home/<name>-<16 hex>`, rig's own | `createFile` follows a `.lock` symlink (N3). Rig never makes one |
| `lockForRemoval` | `createFile(.lock, exclusive)` in a recognized package | `pd` opened `O_NOFOLLOW`; `O_CREAT\|O_EXCL` does not follow links | ok. Creating it bumps the dir time, and `created` uses the time from before |
| `removeEntry .package` | rename to `.trash-<random>`, under the lock, then `deleteTree` | lowercase hex name; d_type dir; `rig` lstat dir; `rig/runtime.zig` lstat regular file | ok |
| `removeEntry .trash` | `deleteTree` | d_type dir named `.trash-<16 lowercase hex>`, in a tagged home | ok, except N2 |
| `removeEntry .stamp/.tag` | `deleteFile` | only at the end of `clean`, and only when the scan found nothing foreign (a non-empty `.trimmed` counts as foreign) | ok |
| `trimCache` | `setTimestampsNow`/`createFile(.trimmed, exclusive)` | tagged home; empty regular file | ok |
| `clean` | `deleteDir(home)` | rmdir, only when nothing foreign, busy, or kept | ok |

Probes confirmed:
- An untagged home is never trimmed, tagged or cleaned.
- A symlinked home is refused by both the trim and `clean`.
- A non-empty `.trimmed`, uppercase hex, a `rig` that is a link, and a
  link named like a package or like trash are all left alone (also
  covered by `cache_trim.sh`).

### N2 (P3). An existing home is tagged when it holds only "trash"

`tagCacheHome` treats an existing directory as rig's when every entry is
a `CacheEntry`. Trash is recognized by its name alone, and an empty
directory has no entries at all. Probe, with `XDG_CACHE_HOME=$X`:
- `$X/rig/.trash-0123456789abcdef/notes.txt` (user data) and no tag.
  `rig run hello.rig` tagged the home, and its own trim **deleted the
  user's directory**. No report was printed.
- An empty pre-existing `$X/rig` is tagged. That marks it for backup
  exclusion (`tar/borg/restic --exclude-caches`) if the user later puts
  files there.

Both need a dir rig did not make sitting at the exact cache-home path,
and the first needs an exactly-named `.trash-<16 lowercase hex>` dir.
This is contrived. Fix: retro-tag an existing home only when it holds at
least one recognized **package** or an empty `.trimmed`, and nothing but
packages and `.trimmed`. Do not count `.trash-*` or emptiness as proof.

## Q2. Lock correctness

**(a) Held for the whole time.**
- `holdPackage` takes `LOCK_SH` before `writePackage` and never closes
  the fd.
- lsof during a running `sleeper.rig` shows the lock is held by `rig`
  only. It is `O_CLOEXEC`, so `zig` and the program do not inherit it,
  and a daemonized grandchild cannot pin a package.
- **Rename race:** I held `LOCK_EX` from perl, started `rig run`, which
  blocked, then renamed the package away and released the lock. The run
  woke, saw that `.lock` was gone (inode check), re-created the package,
  and printed `hi`. Correct.
- **Gaps (N3, P3), all fail-open to "unlocked". None can lose user data,
  but a racing `rig clean` can then fail that run:**
  - `createDirPath ... catch return` and `createFile ... catch return`
    leave without a lock and without marking the package used. The
    second fires if a trim or clean renames the package between
    `createDirPath` and `createFile`. Use `continue` instead.
  - After 8 failed inode checks the loop ends unlocked. This is
    unreachable in practice.
- **Name reuse in `clean` (N3, P3).**
  - `lockForRemoval` opens `pd` by name, locks `pd/.lock`, and
    `removeEntry` then renames *by name*.
  - If another trim renamed that dir away in between, and a run
    re-created `name` and locked it, `clean` renames the run's new
    package. With `aged = true` the trim re-reads the time by name, sees
    a fresh time, and keeps it, so this is `clean` only.
  - Fix: after the lock, check that `name` still has `pd`'s inode, as
    `holdPackage` already does.

**(b) Released on every exit.**
- Kernel `flock`s go with the process. `cache_trim.sh` covers SIGKILL.
  Error exits (`fatal`, `notRun`, panics) all end the process.
- A trim or clean holds `LOCK_EX` only across stat, rename and close, and
  `deleteTree` runs after the close.
- Caveat (P3, note only): SIGTERM to `rig` alone leaves the program
  running, orphaned and unlocked. Its package can go only after 5 days
  (its time was set at start), and unlinking a running binary is
  harmless on Unix.

**(c) Creation-to-lock window and stale lock files.**
- A new package is not recognized until `rig/runtime.zig` exists, and
  that is written after the lock. A reused old package that a trim
  renames before the run's lock is handled by the retry.
- A run's `createFile(.lock)` bumps the dir time, so a trim that did not
  itself create the lock sees the package as fresh.
- The lock file holds no state, so a stale `.lock` is harmless.
- Odd `.lock` kinds:
  - a directory: the run goes unlocked; `clean` can lock it and remove
    the package;
  - a symlink: `lockForRemoval` (`O_NOFOLLOW`) fails, so the package is
    pinned;
  - unwritable: the run goes unlocked.

  Rig never makes any of these.

**(d) Deadlock.**
- None. The only blocking call is the run's `LOCK_SH`. Every `LOCK_EX` is
  a non-blocking `tryLock`, held briefly, and its holder never waits on
  anything while holding it.
- A process's own trim skips its package by name. Even without that, its
  `tryLock` would just see "busy".
- `rig clean` while a run waits: the run blocks for the length of the
  rename, then retries (shown above).
- Only a trim or clean that is SIGSTOPped (Ctrl-Z) mid-rename can make a
  run of that one package wait.

**(e) No locks / network FS.** Interposer results:
- `ENOTSUP` (`FileLocksUnsupported`):
  - the run is fine, unlocked;
  - the trim stops and removes nothing (2 aged packages kept);
  - `clean` exits 1 with "this system has no file locks". **Safe.**
- `ENOLCK` (lock manager down): the run is fine. The trim and `clean`
  treat every package as busy and remove nothing. **Safe.**
  `clean` says "kept 4 packages a run ... is using", which is misleading
  but harmless.
- NFS access-mode rule: **panic in Debug (N1)**. In release, unlocked and
  safe.
- Locks that are local only (Linux `local_lock=flock`, NFS `nolock`)
  across two hosts: a trim on host B cannot see host A's lock. The time
  re-check still protects any run under 5 days old. This is accepted, as
  with other tools.
- Windows (not testable here): `NtLockFile` is used, and renaming a
  directory with an open handle inside it, the trim's own lock, fails.
  So the trim never removes anything there, which is safe.
- Transition (P3, note only): a rig older than this PR (main has no trim)
  neither locks nor sets the package time. A new rig's trim can remove a
  package that an old rig is running when its dir time is over 5 days
  old.

## Q3. test/run store pruning at 2 days

`rig` with RIG_BUILD_STORE rewrites `<entry>/used` at the start of each
run, build or test. A full-suite prune does this:
`find -mtime +$STORE_DAYS -name used | while read; mv entry .trash.$$...`.

**Yes, it can prune an entry a concurrent suite is using (P3).**
- `find` stats every `used` up front, and the `mv` loop reaches each
  entry later. With thousands of entries that is seconds later.
- A run that touches `used` in that window still has its entry moved.
- Reproduced:
  - Setup: a 4000-entry scratch store with a real entry `E`, every `used`
    4 days old, and the exact prune pipeline in the background.
  - In 1 of 8 trials, `E` was moved to the trash 6.3 s after a
    concurrent `rig run` had touched it.
  - It landed after that run finished, so the run passed. A move during
    Zig's cache check or build would fail that test spuriously
    ("did not run" or a Zig error). Unix keeps an already-running binary
    alive.
- This race predates the change. The 2-day value only widens the set of
  eligible entries (`-mtime +2` means idle for 3 days or more, against 8
  before) to builds idle 3 to 7 days. Examples: another worktree's
  branch, or tests carried over by `--delta`.
- `--delta` never runs carried-over tests, so their store entries are
  not touched. After 3 days of `--delta`-only runs they are pruned and
  rebuilt. That costs time but is not a correctness issue. The results
  records themselves are touched (`carried_over`), so they survive.
- No false pass is possible: a pruned build means a rebuild or a failure,
  never a recorded pass.

Mitigation: re-check each entry just before moving it, e.g.
`[[ -n $(find "$entry/used" -mtime +"$STORE_DAYS") ]] && mv ...`. That
shrinks the window from the whole pipeline to one stat→mv. Better, move
first and then check `trash/used`: if it is fresh and `entry` was not
re-created, move it back. Nothing more is needed for test infrastructure.

## Summary of grades

| | Grade | What |
|---|---|---|
| N1 | **P1** | `.lock` open modes: Debug rig panics (EBADF via `errnoBug`) on Linux NFS. Open read-write in both places |
| N2 | P3 | a pre-existing home holding only `.trash-<hex>` dirs, or nothing, is tagged; the first case deletes user data (contrived) |
| N3 | P3 | `holdPackage` `catch return` leaves unlocked (use `continue`); `.lock` symlink followed; `clean` renames by name after locking by fd |
| Q3 | P3 | test/run prune is TOCTOU (pre-existing); 2 days widens it; re-check per entry |
