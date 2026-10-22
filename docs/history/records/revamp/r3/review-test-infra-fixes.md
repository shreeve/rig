# Re-review: `test-infra` fix commits (48e8ab77..93411ac1, diff 48e8ab77..09595e0f)

Reviewer: independent. Worktree /Users/shreeve/Data/Code/rig-test-infra
at 93411ac1, `zig build` clean. All experiments used private stores and
output directories under the session scratchpad
(`$S=.../scratchpad/tif`). The only test/run invocation was 6 tests
(cli/not_run, cli/zig_cache, cli/test_prune, cli/build_store,
corpus/R11a-d1s, examples/hello) through heavy.sh. All 6 passed. I ran
no full suites.

## Verdict

The first review's High-1 is fixed for every way it was reported:

- Repro A (an entry without `o/`) now heals and runs.
- Repro B (an unusable store) now fails as "the program did not run" in
  test/run and in matrix.

Medium-2 (atomic prune) is fixed: no build ever sees half an entry at
an entry's path. Medium-3 (zig_cache tested in only one mode) is fixed:
the test now runs in both modes.

**A false green does remain, but only a narrow one.** test/run and
matrix take "the started path exists" as proof that this attempt ran.
They never check rig's own signal: exit 125 and the
`rig: the program did not run` line. So a corpus or matrix program that
never ran still passes in two cases:

- something they cannot clear sits at the started path (Medium-1,
  reproduced through `./test/run`);
- another job shares the path (Low-2, reproduced at the rig level).

Neither happens on today's tree in a normal run.

Everything else I found is a false red or a nuisance, not a false green.

---

## Medium-1: the started evidence is "a path exists", and corpus and matrix ignore rig's own not-run signal

`not_run` in test/run is `[[ -e "$1.started" ]] && return 1`, after a
`rm -f "$outdir.started"` whose failure is ignored. `matrix.run_one` is
`os.path.exists(started)`. rig does the same: `deleteFile(started) catch {}`
before each attempt, then `access(started)`. If the path cannot be
cleared, a stale object counts as "started". check_corpus and run_one
never look at the exit status. So rig's 125 and its marker line, which
rig prints in exactly this case, are discarded.

The path can be blocked naturally. outdir is `$OUTROOT/<id>`, so the
started path of `corpus/X` is the output directory of `corpus/X.started`.
A corpus file named `X.started.rig` next to `X.rig` makes `X`'s started
path a directory once `X.started` has run, and `rm -f` cannot remove a
directory.

Repro (it stands in for that directory by creating it, since I would not
add files to the worktree):

```bash
cd /Users/shreeve/Data/Code/rig-test-infra
export RIG_TEST_OUT=$S/cout2; : > $S/afile
RIG_BUILD_STORE=$S/afile/store ./test/run -v -j 2 corpus/R11a-d1s
#   FAIL corpus/R11a-d1s — the program did not run: exit 125: ... NotDir   (correct)
mkdir -p $S/cout2/corpus/R11a-d1s.started/.zig-cache
RIG_BUILD_STORE=$S/afile/store ./test/run -v -j 2 corpus/R11a-d1s
#   pass corpus/R11a-d1s    1 passed, 0 failed      <-- never ran
```

rig is fooled the same way:

```bash
mkdir $S/stdir; ZIG=$S/fakezig RIG_RUN_STARTED=$S/stdir bin/rig run ok.rig; echo $?
# zig: boom
# 1          <-- no "did not run" line, status is Zig's, not 125
```

(`fakezig` is a script that prints `zig: boom` and exits 1.)

A related point about rig's contract for other callers: a failure before
rig reaches its run loop leaves a caller's stale file in place. Examples
are an unusable store (`fatal` in `storeEntry`) and a `rig check` error.

```bash
touch $S/st2; RIG_BUILD_STORE=$S/afile/x RIG_RUN_STARTED=$S/st2 bin/rig run ok.rig  # rc=125
ls $S/st2    # still there
```

test/run and matrix delete the file themselves first, so this alone
greens nothing in the tree. But the usage text says the file "proves it
ran", which is true only if the caller clears the file itself.

Fix. Use two independent signals and fail loudly when the slate cannot be
cleaned:

- test/run `not_run` and matrix `run_one`: treat the program as not run
  when the started path is not a regular file (`-f`), or when stderr has
  `rig: the program did not run`. Do the second check before the
  BAD_RE/rc checks, whatever the started path says.
- `run_program` and matrix: after `rm -f`, if the path still exists, fail
  the test with "cannot clear `<path>`". Better, name a fresh path per
  attempt (`mktemp -u` under the outdir's parent, or include `$$`/a
  counter). That way, neither a stale object nor a sibling id can ever
  sit at the path.
- rig: delete the caller's `RIG_RUN_STARTED` once at the start of
  `run`/`test` (before `loadProject`). Treat any delete error other than
  `FileNotFound` as `notRun("cannot clear ...")`. After the run, require
  a regular file (`statFile` kind == .file), not just `access`.

## Low-2: two jobs sharing one RIG_RUN_STARTED path

Repro at the rig level:

```bash
printf '#!/bin/sh\nsleep 3\necho "zig: boom" >&2\nexit 1\n' > slowzig; chmod +x slowzig
RIG_RUN_STARTED=$S/shared ZIG=$S/slowzig bin/rig run ok.rig 2>a.err & a=$!
sleep 1; RIG_RUN_STARTED=$S/shared bin/rig run ok.rig >/dev/null
wait $a; echo $?          # 1, no "did not run" line; $S/shared exists
```

Whether a runner can reach this:

- test/run: no. Each test has its own outdir, and the `$OUTROOT.lock`
  serializes runs that share `RIG_TEST_OUT`.
- matrix.py: yes, but only with `--keep DIR`. Then the path is
  `DIR/<ident>.started`, and nothing locks DIR. gates.sh uses a fixed
  `--keep "$W/.zig-cache/rig-matrix"`, so two gate runs in one worktree
  at once share every started path. Without `--keep` it uses `mkdtemp`,
  which is safe.

Fix: the per-attempt unique path from Medium-1 fixes this too. Or have
matrix take a lock on `--keep DIR`, as test/run does.

## Low-3: prune can still delete an entry a running build is using (false red, never green)

The trash rename works: a build never sees half an entry at the entry's
path. Each prune deletes every `.trash.*`, including other prunes' trash,
which is harmless. If a recycled PID makes the trash name collide, `mv`
nests the entry inside the old trash, which is also harmless.

The remaining race is a gap between check and use:

1. `find ... -mtime +N` reads `used`.
2. Another worktree's `rig run` rewrites `used`, writes the package, and
   starts `zig run` on the entry.
3. The prune `mv`s the entry away and deletes it.

Deterministic repro: `$S/race.sh $S 0.5`. It selects an old entry, starts
a build that must recompile, then runs the prune's exact `mv`/`rm` lines.

```
rig rc=125
error: failed to open rstore/<entry>/o/<digest>/__rig_main_zcu.o: FileNotFound
error: rig: the program did not run: `zig run` exited with status 1 before it started the program
```

The result is a transient false red (125), and the next run rebuilds.
The window needs an entry unused for ≥ `RIG_BUILD_STORE_DAYS` days, built
again at the moment of a no-filter run's prune in another worktree.

Fix, if wanted:

- rig holds a shared `flock` on `<entry>/used`, or on the entry directory,
  from `storeEntry` to the end of the run;
- the prune takes it exclusively with `LOCK_NB` before the `mv`, and
  skips the entry if it is busy.

Or, after the `mv`, recheck `used` in the trash and `mv` it back if it is
fresh. That is cheaper, but a gap remains.

## Low-4: the heal covers only "`o/` missing"; "`o/` present but the binary gone" is a persistent false red

The heal condition is `exists(h) and !exists(o)`. If `o/` exists but this
build's `o/<digest>/` is missing, the heal never fires. An interrupted
`rm -rf` that got partway into `o/` leaves this state, and so does any
external cleaner. The entry stays poisoned, because every use rewrites
`used`.

```bash
bin/rig run se.rig; B=$(dirname $(find $E/o -name __rig_main)); rm -rf $B
bin/rig run se.rig    # failed to execve ... FileNotFound; rig: the program did not run (125)
bin/rig run se.rig    # same, every time
# ./test/run corpus/R11a-d1s after the same edit: FAIL ... did not run, every run
```

The trash rename stops this branch's own prune from producing that
state, so this is Low. Fix: on a first attempt that did not start, with
`h/` present, drop `h/` and retry once, whatever `o/` holds. Zig then
rebuilds against the remaining `o/` contents. The cost is a second Zig
invocation only on a run that already failed before starting. A genuine
Zig compile error would be compiled twice. If that matters, keep the
coarse check, and add the case where `o/` exists but has no executable
named after the root.

Two more notes on the heal:

- **It cannot loop.** `attempt == 0` bounds it to 2 attempts. I
  verified with `o` replaced by a dangling symlink: two attempts, then
  125.
- **It cannot run a program twice.** A retry needs the started file
  missing and `o/` missing. A program that ran was executed from `o/`,
  so `o/` exists unless the program deleted it itself.
- **Cosmetic:** when the heal succeeds, Zig's
  `error: the following command failed to execve with 'FileNotFound'` is
  still printed on the user's stderr above correct output.

## Low-5: the program ran, but rig says it did not

If `rig.start` cannot create the file (it swallows the error), the
program runs in full and then rig exits 125. Its message claims Zig exited
"before it started the program". The causes are an unwritable directory,
`ENOSPC`, or `EMFILE`.

```bash
mkdir ro; chmod 555 ro; RIG_RUN_STARTED=$S/ro/s bin/rig run ok.rig
# ran
# error: rig: the program did not run: `zig run` exited with status 0 before it started the program   (rc=125)
```

When rig picks the path itself, the directory is one rig just wrote to,
so this needs a caller-named path or a full disk. The wording could say
"no evidence the program started (status N)" rather than asserting what
happened.

## Low-6: nested `rig run` inherits RIG_RUN_STARTED and erases the parent's evidence

Every program `rig run` starts gets `RIG_RUN_STARTED` in its environment.
Suppose a child `rig run` inherits it, for example a program, script or
tool that a test runs. That child deletes the parent's file before its
own attempt. If the child then fails before starting, the parent, which
did run, is reported as not run:

```bash
RIG_RUN_STARTED=$S/nest bin/rig run ok.rig            # nest created
RIG_RUN_STARTED=$S/nest ZIG=$S/fakezig bin/rig run ok.rig   # 125
ls $S/nest                                             # gone
```

This is a false red only. A program can never cause a false green this
way, because it must have started before it can spawn anything. Safe Rig
cannot spawn a process today: std has no spawn, and only integers cross
`extern`.

The variable is also visible to the program: `os.env("RIG_RUN_STARTED")`
is set under `rig run` and absent from the built binary. The two differ
observably; it is harmless.

## Low-7: started files are left behind when rig is killed

If rig is killed while the program runs (Ctrl-C, SIGTERM), its own file
stays:

- `.started-<hex>` in the output directory (default
  `~/.cache/rig/<project>/`);
- `.started/<hex>` in the store root.

Reproduced both. Nothing prunes either: test/run's store prune selects
only `*/used`. Empty files, unbounded count. Fix: have
`./test/run --prune` (or rig, on a store run) remove `.started/*` older
than a day.

## Low-8: `known` and `pending` absorb "did not run"

- **known:** a known-bug behavior test that did not run is reported as
  `known` (expected failure), so an infrastructure fault hides `fixed`.
- **pending:** `not_run` keeps a `rejected*` reason from
  `classify_failure`. Rule 3 of `classify_failure` classifies any stderr
  matching `parse error|unexpected` without `.zig:` as `rejected:`. Zig's
  or the OS's "unexpected ..." texts (`unexpected errno`, and so on)
  would then make `pending_holds` accept an example that never ran as
  "held".

Neither greens a claim that something works, but both green a claim that
the suite checked something. Fix: in `not_run`, keep `rejected` only when
stderr has a `.rig:L:C: error` line. Have test/run's `known` branch treat
"the program did not run" as `fail`.

## Low-9 (predates the branch, within the question): corpus and matrix ignore a signal death after start

Once the started file exists, check_corpus and run_one look only at
`CORPUS_BAD_RE`/`BAD`. A program killed with no stderr output passes.
Examples are SIGKILL from jetsam under memory pressure, or SIGTERM: I
measured rig passing 137 and 143 through with empty stderr.

Under `rig run`, Rig panics exit 1 (measured), so status > 128 is never
a Rig panic. Suggest failing corpus and matrix programs on rc > 128 (124
is already the timeout). Note that a panic inside `rig test` aborts with
134, but no runner uses `rig test`.

---

## Answers to the questions

**1. False greens.**

| Case | Result |
|---|---|
| A program exiting 125 itself | Correct. No marker, rc 125, file present, both with and without `RIG_RUN_STARTED`. |
| Stale started file | Cleared by test/run (`rm -f`) and matrix (`os.remove`) before each attempt, and by rig before each of its attempts. It survives when it cannot be deleted (a directory: Medium-1), and when rig fails before its loop (Medium-1, harmless for in-tree runners). |
| Two jobs sharing one path | False green at the rig level (Low-2). Not reachable in test/run. Reachable in matrix only with a shared `--keep`. |
| A program that forks or spawns `rig run` | Only a false red (Low-6). |
| `rig test` with zero tests | Prints `0 passed, 0 failed`, exit 0, file created. This is intended (`test_blocks.sh` checks it), and no runner uses `rig test`. |
| Killed by a signal after start | rc 128+n is passed through. Behavior tests fail it. Corpus and matrix pass it when stderr is empty (Low-9, predates the branch). |
| Retry loop | At most 2 attempts. It never runs a program twice. It misses the "`o/` present, binary gone" case (Low-4). |

**2. No hidden effect in shipped programs.**

- **Builds:** `rig build` and `--release`, each with the store off and
  on, each plain and with `RIG_SANITIZE=1 RIG_LEAK_TRACE=1`. In all 8
  binaries, `grep -a` finds 0 hits for `RIG_RUN_STARTED` or
  `__rig_run_started`.
- **Packages:** the emitted and store packages contain neither the hook
  declaration nor the variable name. `rig/runtime.zig` mentions
  `__rig_run_started` only in the `@hasDecl` gate and its comment.
- **Built binary at run time:** run with `RIG_RUN_STARTED` set, it
  creates no file.
- **Shared output directory:** `rig run` then `rig build` in the same
  `RIG_OUT_DIR` gives a binary without the hook.
- **User declarations:** a root `__rig_run_started` (constant, `pub`
  constant, function, local) is accepted by `rig check`, and emit mangles
  it to `@"__rig_run_started'"`. It neither turns the hook on nor
  collides, under `run` and under `build`.
- **`extern zig`:** a user cannot use it ("only the standard library
  binds..."), and a shim is never the root anyway. Harmless.

**3. Prune and heal.**

- No build sees half an entry at the entry's path.
- A prune can delete an entry a concurrent build is using. This is the
  gap between find's check of `used` and the `mv`, reproduced
  deterministically, and it gives a transient 125 (Low-3).
- The heal is bounded, but incomplete (Low-4).

**4. CLI.**

- **`rig build`:** exit codes are unchanged. A Zig failure gives 1 plus
  `note: emitted Zig is in ...`, a check error gives 1, and success gives
  0.
- **`rig emit`:** still writes to `RIG_OUT_DIR`, or to
  `$XDG_CACHE_HOME/rig/<name>-<hash>`, without the hook.
- **Error messages:** diagnostics and Zig's errors are still printed.
  `run`/`test` add one `error: rig: the program did not run: ...` line,
  and a Zig error return from `buildCommand` now prints its name in that
  line instead of a return trace.
- **`rig run` itself:**
  - arguments after `--` reach the program unchanged (spaces,
    leading-dash args), and arguments without `--` are still a usage
    error, rc 2, as before;
  - stdin is inherited (a `getchar` via `extern` reads piped input);
  - stdout is unchanged;
  - `fun main -> Int` returning 7 gives 7, the same as main's rig;
  - a panic gives 1, the same as main's rig;
  - a signal gives 128+n;
  - the environment reaches the program byte-for-byte (`=`, empty and
    non-UTF-8 values; compared against main's rig);
  - an empty `RIG_RUN_STARTED=` counts as unset.
- **The one intended change:** a failure before the program starts in
  `run`/`test` exits 125 instead of Zig's 1. It is documented in
  `--help` and INTERNALS, and std_shims.sh was updated.

## Other fix commits, spot-checked only

- **f36e7daf (equiv):** it hashes case-variant names, caches only
  `rc >= 0` (and only success for accepted sections), and fails equal
  failures (`name(failed)`). This addresses Low-5 of the first review.
- **3bd38b1c:** classify fails on grep status > 1, and vocab fails on an
  empty `git ls-files` or a perl failure. The logic reads correctly. I
  did not inject faults.
- **test/run discovery:** it now uses `find -L` and stops on errors
  (first review's Low-4).
- **`--shard`:** `LC_ALL=C` on the shard hash, and matrix rejects
  `--oracle --shard` (Low-6).
- **AGENTS.md wording:** fixed as suggested (Low-7).
- **Doc nit carried over:** docs/INTERNALS.md still says `build` "caches
  nothing, so it compiles the package in full every time", but with a
  store, `rig build` builds in a store entry (build_store.sh).
