# coreutils: the Rust baseline (tests and benchmarks)

The tables beside this report are generated: [per-util.md](per-util.md) (per-utility tests), `kinds.txt` (kinds of check), [bench-tables.md](bench-tables.md) (all 200 bench specs and the baseline numbers), with `bench.py` and its helpers. The logs and `baseline.json` are on pup in `/zfs/trig-pup/records-data/rust-ports/coreutils/panel/tests/`.

**Tests (macOS)**
- **Integration tests** (`tests/by-util`): 5889 passed, 12 failed, 67 ignored, 5968 cases in all. The tests themselves are the reusable part. None imports a `uu_*` crate, so they run against a Rig multicall binary with `UUTESTS_BINARY_PATH=BIN cargo test --features unix --test tests`.
- **Unit tests** (not reusable, Rust internals): 665 in `src/uu/*/src` and 474 in uucore, all passing. The harness's own crate: 27 passed, 1 failed.
- Note that `--features unix` alone skips the unit tests; they need `--workspace`.

**Failures**
- One was my mistake: running the suite as a background job made it ignore SIGQUIT, which broke the stdbuf test. It passes in the foreground, so the real result is **5890 passed, 11 failed**.
- **Ten fail because passwordless sudo works on this Mac.** The suite really did run commands as root: 8 chroot tests, `id` on a setuid copy of the binary, `install`, and one harness test. `CI=true` skips these.
- **Only two failures are macOS itself.** `install` gives a new file its directory's group (gid 20, not 0), and this Mac's hostname doesn't resolve, so `hostname -i` fails.

**What the tests check** (5707 test functions): 82% check success or failure, 37% exact stdout, 19% exact exit codes, 13% exact stderr, 17% fixture files, 18% piped stdin, 4% set the locale, 2% set TZ, 1% run as root, 1% need a terminal, 7% are compiled for Linux only.

**Benches:** 201 divan benches; 200 are ported and every input generator matches Rust byte for byte. Three Rust benches are broken: two base64 ones time an error path or an empty file, so I used 100 MB inputs instead. `df` is 2000 directories deep on macOS instead of 20000, because each level takes longer to create than the last.
- `bench.py` takes `NAME=PATH` or `NAME=prefix:/opt/homebrew/bin/g` arms. It interleaves and rotates the arms, reports the fastest and median time and peak RSS, and compares outputs.
- Baseline, Rust against GNU: 587 s at load 4.0–6.3, so expect noise. GNU's output differs on 13 benches (it lacks blake3 and shake, and ptx, od -c, numfmt, sort -f/-d and a 10,003-digit seq differ). GNU has no `hostname`.
- Over the 185 benches whose outputs match, GNU is 8% slower than Rust (geometric mean of the fastest times).
- **Starting a process costs 4.6 ms for uutils against 1.3 ms for GNU**, so benches under about 10 ms mostly time startup.

**Linux (pup) would add:** about 320–420 Linux-only tests, chcon and runcon, the nss_wrapper hostname bench, the full 20000-deep `df`, x86 timings, and GNU's own test suite (`util/run-gnu-test.sh`). Its GNU arm needs a separate GNU install, since pup's own `wc` and `sort` are uutils.
