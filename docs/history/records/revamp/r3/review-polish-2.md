# Review: PR #95 `polish` (head ac9dcd8a), round 2: cache deletion only

Scope: `git diff aea73c3f ac9dcd8a -- src/main.zig test/cli/` (cacheHome,
CacheEntry, runInProgress, unused, removeEntry, trimCache, clean, and
test/cli/cache_trim.sh). The F3 change (typecheck/ownership/sema) touches
no file system call, so it is out of scope.

I built ac9dcd8a in a detached scratch worktree (since removed) and ran
every probe with HOME, XDG_CACHE_HOME and ZIG_GLOBAL_CACHE_DIR inside a
scratch directory. I also built two scratch variants, not committed: one
that counts a future time as fresh, and one that logs each rename and the
writePackage times. They were used to find the cause of R1. The PR's own
`cache_trim.sh` passes in isolation.

**Grades.** P1: fix before landing. P2: should fix this round. P3: polish.

## Verdict

**Rig never deletes, renames or changes anything it did not make, apart
from two trivial P3 cases (S1).** F1 is fixed:
- A relative, empty or `~` `XDG_CACHE_HOME`/`HOME` is ignored.
- `rig clean` removes only entries it recognizes, and removes the home
  with a plain `rmdir`.
- Symlinks are never followed into user data.
- No user file was lost in any probe, including stress runs of 4
  concurrent trims racing `rig clean` over 450 packages with user
  directories mixed in.

The deletion code is **safe to land as far as user data goes**. There are
two P2 robustness problems, both about rig's own files. Neither can
destroy user data, but both cause spurious failures or leave the cache
pinned:
- R1: the F2 re-check is defeated, and concurrent runs fail 16-28% of the
  time after an idle week.
- R2: Ctrl-C pins a package forever.

## What deletes, renames or touches a file (all read)

| Site | What | Guard |
|---|---|---|
| `removeEntry` `.stamp` | `deleteFile(".trimmed")` | regular file (d_type) named `.trimmed` |
| `removeEntry` `.package` | `rename(name, .trash-<16 hex>)`, then `deleteTree` | dir (d_type, not a link) `<name>-<16 hex>` holding regular file `rig/runtime.zig` (lstat) |
| `removeEntry` `.trash` | `deleteTree(name)` | dir (d_type) `.trash-<16 hex>` |
| `trimCache` | `setTimestampsNow`/`createFile(".trimmed")` | lstat: only a regular file is touched; a link or a directory stops the trim |
| `clean` | `deleteDir(home)` | only when every entry was rig's and was removed (rmdir, so only an empty dir) |
| `buildCommand` (pre-existing) | `setTimestampsNow(dir)` | the package's own path |

`std.Io.Dir.deleteTree` opens each subdirectory with
`follow_symlinks = false`, and a link is unlinked, never descended into.
Trash is always made in the cache home itself, by renaming in place, so
nothing leaves the home.

## Cache base resolution (all probed with `rig clean`)

| XDG_CACHE_HOME / HOME | Home used |
|---|---|
| `""`, `.`, `rig`, `../x`, `~/x` | ignored, falls back to `$HOME/.cache/rig` |
| `/` | `/rig` (only rig's entries; not writable by users anyway) |
| `//`, trailing `/` | `//rig`, `x/rig` (cosmetic) |
| `/a/home/../xdg` | used as is; the OS resolves it (fine) |
| `$HOME` | `$HOME/rig`; a source tree there is kept (PR test) |
| HOME `""` or `.`, XDG unset | error: "set XDG_CACHE_HOME or HOME to an absolute path" |
| HOME `/` | `/.cache/rig` |
| XDG is a symlink to a dir | followed (an intermediate path component); cleaned correctly |
| `$XDG/rig` itself a symlink | **trim follows it, `clean` refuses it** (`O_NOFOLLOW`) and says "nothing to clean" (S3) |

## Recognizer probes (trim and clean; user files all survived)

- `a-<hex>/rig` → symlink to a user dir holding `runtime.zig`:
  recognized as a package, because `statFile(..., follow_symlinks =
  false)` applies only to the last component. On deletion only the link
  is unlinked, and the user's file stays. Safe, but the recognizer does
  not check the real path (S2).
- `c-<hex>/rig/runtime.zig` → symlink: not recognized (lstat). Correct.
- Package holding links to user data (`.zig-cache` → user dir, `x.zig`
  → user file): package removed, targets intact.
- `l-<hex>` → symlink to a dir: not recognized (d_type is a link).
  Correct.
- `.trash-<hex>` → symlink to a user dir: not recognized. Correct.
- `.trimmed` → symlink to a user file: trim stops (it never touches it),
  and clean keeps it.
- Uppercase hex (`d-0123456789ABCDEF`) is accepted (`isHex`), although
  rig writes only lowercase (S2). A 15-hex name, an empty program name,
  and `.trash-...g` are rejected.
- On a filesystem whose readdir returns `DT_UNKNOWN`, Zig reports
  `.unknown`, nothing is recognized, and trim and clean do nothing. That
  is safe, though the cache is never cleaned there.

**Could a user directory match?** It would need to be in the cache home,
at top level, named `<anything>-<16 hex>`, and hold a regular file
`rig/runtime.zig`. The only route to a non-cache directory is
`XDG_CACHE_HOME=$HOME` with `~/rig` being the user's own directory, and
then it would also need such a subdirectory, which in practice means a
copy of a rig package. I judge that unrealistic. A stronger marker is
cheap all the same; see S2.

## Rename-then-delete and crashes

A SIGKILL during a 80,000-file `deleteTree` left `.trash-d25a9e1dc87ac198`,
which matches the recognizer, and the next `rig clean` removed it
(observed). A crash can only leave a `.trash-*` dir of rig's own content,
a renamed package, or a fresh `.trimmed`. Nothing unsafe. Trash gets no
age or liveness check, which is right because only a rename by rig makes
it. Two trims deleting the same trash at once ignore each other's errors,
which is harmless.

The rename has no `RENAME_NOREPLACE`, so it would replace an existing
*empty* directory named `.trash-<that random 64-bit tag>`. That chance is
negligible.

## R1 (P2). Concurrent runs after an idle week fail spuriously; the F2 re-check does not hold

Probe: four programs (`h1..h4.rig`), each with a cached package. In each
round, the packages and `.trimmed` were set to 2020, then the four ran
`rig run` at once. Over 25 rounds:

| Binary | Failed runs (of 100) |
|---|---|
| ac9dcd8a | **28** |
| scratch variant counting a future mtime as fresh | 16 |

A typical failure: `h3-.../rig/runtime.zig: unable to load "runtime.zig":
FileNotFound`, then `error: rig: the program did not run` (status 1, or
125 in other interleavings). There are two causes.

1. **A future time counts as old, measured against a stale `now`.**
   `trimCache` reads `now` once, and `unused` re-checks against it. A
   package that a concurrent run touches after that instant has an mtime
   in the trimmer's future. Because `age < 0` counts as old ("a clock set
   back"), the re-check removes exactly the package it was meant to keep.
   Shown directly: a package touched 1 minute in the future is removed at
   once ("removed 1 package unused for 5 days").
2. **writePackage runs before the touch.** The instrumented build shows
   the interleaving: h3's `writePackage` ran from ...328179 to ...328999,
   and h1's trim renamed `h3-...` at ...328339. h3 had compared
   `rig/runtime.zig` in the old directory (unchanged, so not rewritten),
   then wrote the root into a fresh directory, which lacks the runtime.
   Review 1 suggested moving the touch before `writePackage`, and it was
   not moved.

None of this harms user data, since it deletes only rig's own package.
But this is how anyone hits it: parallel `make -j`, CI jobs, or an editor
and a terminal, on the first run after five idle days.

**Fix (any of):**
- (a) Minimal:
  - In `buildCommand`, create the package dir and `setTimestampsNow` it
    *before* `writePackage`.
  - In `unused`, read the clock afresh.
  - Count a future mtime as fresh, or as old only when it is more than a
    day ahead.
  - This shrinks the window to stat→rename against a touch that happened
    just before it, but does not close it.
- (b) Sound, one mechanism for R1 and R2: a `flock` on the package dir.
  - `run`, `build` and `test` open the package dir and hold `LOCK_SH`
    from before `writePackage` until the program exits. After taking the
    lock, they check that the path still names the same inode (fstat
    against stat), and retry if not.
  - Trim and `clean` open each candidate with `O_NOFOLLOW|O_DIRECTORY`,
    try `LOCK_EX|LOCK_NB`, skip it if busy, and rename while holding the
    lock.
  - The kernel drops the lock when a process dies, so neither a killed
    run nor a clock problem matters. The `.started-*` scan is then needed
    only for its current job, proving the program started.

Add a CLI test: two different programs with stale packages run at once,
in a loop. The 28% rate makes 10 rounds enough to catch it.

## R2 (P2). Ctrl-C leaves `.started-*`, which pins the package forever

Rig installs no signal handling. With SIGINT sent to the process group of
a running `rig run long.rig` (what Ctrl-C does): rc=130, and
`.started-5aaadc27afbfc3c6` stays in the package. After aging it:
- trim skips it;
- `rig clean` prints "kept 1 package a run is using" (false), and keeps
  the cache home.

Running the same program again deletes only its own new marker, so the
old one never goes. Ctrl-C is the usual way to stop a server or a long
job, so packages accumulate, and `rig clean` cannot empty the cache
without manual `rm`.

**Should a stale `.started-*` (older than a day) count as dead?** Not on
its own. A server run for more than five days has a package and a marker
both older than the limit. The trim would then delete its package while
it runs, and rig would report "the program did not run" (exit 125) when it
ends: F2 again. (The `test/run` store pruning uses `-mtime +1`, but there
no run lasts a day.) Better options:
- Ignore SIGINT (and SIGTERM, SIGHUP) in rig while it waits for the
  child, as `go run` does. The child still gets the terminal's signal,
  and rig then deletes the marker. This fixes the common case cheaply.
- For SIGKILL, OOM or power loss: the flock of R1(b), or put rig's pid
  and hostname in the marker name (`.started-<host>-<pid>-<hex>`). Count
  a marker as dead only when the host matches and `kill(pid, 0)` gives
  `ESRCH`. A reused pid only keeps the package, which is the safe
  direction. A foreign host counts as alive (NFS homes).
- If an age rule is kept anyway, make it long (30 days) and combine it
  with the pid check, not instead of it.

## S1 (P3). The two cases where rig touches something it did not make

Both are trivial, both are shown by a probe, and both arise only with
`XDG_CACHE_HOME=$HOME` or a hand-made cache home.
- `rig clean` `rmdir`s an empty cache home that rig never wrote to (an
  empty `~/rig` with `XDG_CACHE_HOME=$HOME`: removed).
- `rig clean` deletes any regular file named `.trimmed` in the home,
  whatever it holds (a user's `~/rig/.trimmed` containing "mine":
  removed). Rig's stamp is always empty, so require `size == 0`.
- Alternatively, remove the home only if `.trimmed` (an empty one) or a
  package was found in it.

## S2 (P3). Harden the recognizer

- Accept lowercase hex only. `outputDir` and the trash tag write only
  lowercase.
- Check the real path. Open the package dir with `O_NOFOLLOW`, then
  lstat `rig` (a directory, not a link) and `rig/runtime.zig` relative
  to it. Today an intermediate `rig` symlink is followed (deletion is
  still safe).
- If a stronger marker is wanted:
  - Write a `CACHEDIR.TAG`, with the standard signature line, into the
    cache home *only when rig creates it*.
  - Have trim and `clean` act only on a home that holds it. This retires
    the `XDG_CACHE_HOME=$HOME` → `~/rig` worry entirely, and makes backup
    tools skip the cache as a bonus.
  - A per-package `rig/runtime.zig` plus the name pattern is otherwise
    enough.

## S3 (P3). Smaller points

- A symlinked cache home (`~/.cache/rig` → elsewhere) is trimmed but
  never cleaned, and `rig clean` reports "nothing to clean in ...", which
  is false. Either follow it as the trim does (safe, since entries are
  recognized) or say that it is a link and not cleaned.
- `rig clean` racing a run that is compiling removes its package, and the
  run fails (seen in the stress test). This is acceptable as an explicit
  user action. With R1(b)'s lock, `clean` would skip it.
- When `clean` loses a rename race to a concurrent trim, it sets `others`
  and prints "kept <home>, which holds files rig did not make", which is
  wrong. Count a vanished entry as removed.
- Tests do not yet cover these cases:
  - a symlinked cache home;
  - a package whose `rig` is a link;
  - a `.trash-*` link;
  - a `.trimmed` link;
  - concurrent runs (R1);
  - an interrupted run (R2).

  The probes above can become those tests.
