# coreutils in Rig: the shared framework

The framework every utility shares, proven on `true`, `false`, `yes`, `echo`,
`basename`, `dirname` and `wc`. The code is in `~/Data/Code/rig/compare/rig/coreutils/`
(a copy of `coreutils/` here). `rig` at main `6c150dfa8`, Zig 0.17, macOS arm64.

**Result: all 192 of uutils' own tests of the seven utilities pass**, unchanged, against
the Rig multicall binary, in a release build and in a debug build run with
`RIG_SANITIZE=1` (leak-checked, so no leak either). No compiler bug: everything
`rig check` accepted compiled and ran.

## 1. Layout

```
coreutils.rig                     the multicall program      (src/bin/coreutils.rs, common/validation.rs)
src/uucore/                       module src.uucore          (src/uucore/src/lib/)
  util.rig    Util: name, phrase, exit code, buffered stdout; show, show_error, eprint
  error.rig   error UError: simple / usage / io / exit; describe(e), strerror
  args.rig    App, Opt, Matches: the argument parser and clap's error text
  help.rig    help_text, wrap: clap's help layout
  io.rig      open ("-" is stdin), stat, Records (split by a byte)
  quoting.rig quote, escape: shell-escape quoting under LC_ALL=C
  format.rig  unescape: echo -e escapes
  signals.rig restore_sigpipe
src/uucore/locales/en-US.ftl, en_us.rig        module src.uucore.locales
src/uu/<util>/<util>.rig                       module src.uu.<util>   (src/uu/<util>/src/<util>.rs)
src/uu/<util>/locales/en-US.ftl, en_us.rig     module src.uu.<util>.locales
tools/ftl2rig.py                  writes en_us.rig from en-US.ftl
tests/run.sh [UTIL...]            builds bin/coreutils, runs uutils' tests against it
```

Rust's extra `src/` level under each utility is dropped: a Rig directory is already a
module, so `src/uu/wc/` holds `wc.rig` and would hold `count_fast.rig` beside it, as
Rust's submodules. `use` paths start at the root file's directory, so the multicall
root sits at the top and every utility is `use src.uu.wc`. The binary dispatches on its
first argument (`coreutils wc -l`) and on its own name (a link named `wc`, longest
suffix wins, as uutils), so `UUTESTS_BINARY_PATH=bin/coreutils cargo test --features unix
test_wc::` checks it.

## 2. uucore's API

```rig
pub sub uumain(u: !uucore.Util, args: []Static)!uucore.UError      # every utility
```

- **`Util`** replaces uucore's globals (Rig has none): `u.name`, `u.phrase`
  (execution_phrase), `u.code`; `!u.write(s)!`, `!u.push(b)!`, `!u.flush()!`;
  `!u.show(e)` (show!: prints, sets the code, goes on), `!u.show_error(msg)`,
  `!u.set_exit_code(n)`, `!u.eprint(line)` (stderr after flushing stdout, so a
  `2>&1` run reads in order), `u.version()`.
- **`error UError`**: `simple(code, msg)` = USimpleError, `usage(code, msg)` = UUsageError
  (adds `Try 'PHRASE --help' for more information.`), `io(context, reason)` = UIoError
  (`util: context: No such file or directory`), `exit(code)` = ExitCode (already reported;
  also --help's 0). `uucore.io_error(context, e)` builds an `io` from any failure.
  The dispatcher catches whatever `uumain` fails with, shows it, flushes, returns `u.code`.
- **Strings**: `tools/ftl2rig.py` turns each `.ftl` into Rig declarations: a constant
  for a plain message (`tr.ABOUT`), a typed function for one with placeables
  (`tr.error_read_error(path)`, `tr.checksum_bad_format(count: Int)` with its select
  expression as a conditional). Checked names, no runtime parser, en-US only (LC_ALL=C).
- **stdout**: 64 KiB buffer, written to `/dev/stdout` when full or flushed; a block of
  64 KiB or more goes straight through. Broken pipe: `restore_sigpipe()` at start, so
  `yes | head -1` dies by SIGPIPE (status 141), which test_yes checks.
- **input**: `uucore.open(path)` (`-` = stdin), `uucore.stat(path)`,
  `Records.new(f, "\x00")` with `(!r).next() -> String?!` (BufRead::split).
- **quoting**: `quote(s)` (always quoted, `.quote()`), `escape(s)` (only when needed,
  locale_aware_shell_escape): `'dir with spaces'`, `"it's"`, `'a'$'\n''b'`.

## 3. The argument parser

A spec is built, not derived:

```rig
pub fun app() -> uucore.App
  a = uucore.App.new("wc", tr.ABOUT, tr.USAGE, infer: true)
  !a.flag(:bytes, 'c', "bytes", tr.HELP_BYTES)
  !a.option(:total, 0, "total", "WHEN", tr.HELP_TOTAL)
  !a.choices(:total, ["auto", "always", "only", "never"], hidden: true)
  !a.flag(:debug, 0, "debug", "", hidden: true)
  !a.operands("files")
  a
...
m = app().parse(!u, args)!          # m.flag(:bytes), m.value(:total), m.operands
```

Ids are symbols. It covers what the seven need and what the tests check across the suite:
long options with `=` or a following value, inferred long prefixes (`--tot=o`, `--hel`),
combined shorts (`-lwc`, `-sx`, `-s=x`), `--`, `-` as an operand, trailing operands
(basename's `a -z`), last-wins repeats, a default operand (yes's `y`), choices with
unique-prefix matching (ShortcutValueParser), auto `-h/--help/-V/--version` (or a
utility's own, as true/false). Errors, byte for byte as uucore prints clap's: unexpected
argument (with clap's Jaro "similar argument" tip, or the `-- ARG` tip when the utility
has operands), unexpected value for a flag, missing value (with possible values),
invalid value; exit 1. `help_text` reproduces clap 4.6's layout: per-section column
alignment, `[default: y]`, `[possible values: ...]`, next-line help, wrapping at 100.
Survey: across all tests, `usage_error` 65 checks in 20 files, `--help` 95 in 43,
"unexpected argument" 22, "invalid value" 22, "required arguments" 14, "cannot be
used with" 9, "a value is required" 7. Not built yet: required options, conflicts,
multi-value and optional-value options (`--color[=WHEN]`), subcommands.
Size: args.rig 274 lines, help.rig 140.

## 4. Tests

`tests/run.sh` (= `UUTESTS_BINARY_PATH=.../bin/coreutils cargo test --features unix --test
tests -- test_wc:: ...`), release build; the same with the RIG_SANITIZE debug build:

| utility | passed | failed | Rust lines/tokens | Rig lines/tokens |
|---|---:|---:|---:|---:|
| true | 6/6 | 0 | 50 / 361 | 13 / 158 |
| false | 6/6 | 0 | 50 / 361 | 14 / 165 |
| yes | 8/8 | 0 | 99 / 999 | 22 / 214 |
| echo | 65/65 | 0 | 163 / 1,159 | 51 / 458 |
| basename | 29/29 | 0 | 124 / 988 | 39 / 445 |
| dirname | 21/21 | 0 | 141 / 1,168 | 38 / 400 |
| wc | 57/57 | 0 | 1,233 / 9,192 | 406 / 3,913 |

(Lines and tokens by `rust-ports/sloc.py`, tests left out; uucore's Rust counterparts
come to 1,431 lines, the Rig uucore and dispatcher 853.) The one failure on the first run
was mine (`files0_from_dir`: a read error names the list `-`, not "standard input").
Linux-only tests (`/dev/full`, `/proc`) are compiled out on macOS. `ref/compare.sh` runs
both binaries on 115 more command lines (every help, version and error text); all match
but `--list`, which lists only the ported utilities.

**Speed** (`ref/bench.py`, wall time, interleaved, fastest of 7, 96 MB text, `tools/low`):

| case | Rust | Rig | |
|---|---:|---:|---|
| `wc` | 121.3 ms | 37.4 ms | 3.2x faster |
| `wc -w` | 99.6 | 38.3 | 2.6x faster |
| `wc -c` | 4.3 | 2.7 | faster |
| `wc -l` | 11.0 | 13.4 | 22% slower |
| `wc -m` | 10.7 | 13.0 | 22% slower |
| `wc -L` | 113.6 | 146.1 | 29% slower |
| `wc` on 50 MB of `y\n` | 37.9 | 11.3 | 3.4x faster |
| `yes` through a pipe | 7.36 GB/s | 6.73 GB/s | 9% slower |

uutils' benches are divan benches of `uumain` in process, so they cannot run against
another binary; these are their cases (`benches/wc_bench.rs`, BENCHMARKING.md) as
whole runs. `-l`/`-m` lose on reading alone (gap 3), `-L` is a rune at a time in both.

## 5. Gaps in Rig

No compiler bugs. In order of what they cost the port:

1. **No standard streams in std.file.** Stdin is `file.open("/dev/stdin")` and stdout
   `file.create("/dev/stdout")`. On macOS opening `/dev/fd/N` duplicates the descriptor,
   so `>>` survives; on Linux it reopens the file, and `create` would truncate a `>>`
   target. Wanted: `file.stdin()`, `file.stdout()`, `file.stderr()` as `File`s, and a
   way to ask whether one is a terminal (clap's colors, line buffering).
2. **`FileError` drops errno.** ENOSPC, EPIPE, EBADF, ELOOP, EINVAL all become `failed`,
   so `true: No space left on device` prints as `Input/output error` (Linux tests).
   Wanted: the system's message, or errno, on the error.
3. **`File.read` allocates a fresh buffer every call**, and each read and write hops to
   the blocking pool through a dup'd descriptor. Reading 96 MB costs 12 ms against `cat`'s
   8 ms; that is all of `wc -l`'s loss. Wanted: a read that refills a buffer it is given.
4. **SIGPIPE.** The runtime turns a closed pipe into exit status 0; GNU and uutils die by
   the signal (`test_yes` checks it). The port calls `signal(13, SIG_DFL)` in `raw`;
   whether the parent ignored SIGPIPE is lost, since the runtime replaced it first.
5. **No user `extern zig`, no raw pointers**: nothing beyond std can reach `read(2)`,
   `fstat`, `isatty`, `splice`. C externs take only numbers.
6. **CPU features**: std.target knows the architecture, not AVX2, so `wc --debug` on x86
   can only guess.
7. **Smaller frictions**: `use` paths start at the root, so a standalone `src/uu/wc/main.rig`
   cannot reach uucore (multicall only, plus links); a local or a pattern binding may not
   share a name with any declaration of the directory module (`code`, `reason`, `width`
   had to be renamed); `List([...])` of objects is rejected (hence the builder); `true` and
   `false` modules need `use ... as true_`; a single-quoted literal takes no escapes, so
   `'\n'` is two bytes.

## 6. The idiom: one example from wc

Rust walks every char with `ch.is_whitespace()`. The Rig port counts 64 bytes of ASCII at
once (and falls back to a rune at a time elsewhere):

```rig
  # Counts 64 bytes of ASCII at once: a word starts at each byte that is not a space
  # after one that is, the byte before the first being the last one counted.
  sub block(!@, v: Block, s: ?Settings)
    if s.words
      before = v.lag[1](Block.splat('a' if @in_word else ' '))
      starts = spaces(v).not() & spaces(before)
      @c.words += starts.bits().count_ones()
      @in_word = not spaces(v)[63]
    @c.lines += (v == 0x0a).bits().count_ones()
    @c.chars += 64
```

That is what makes plain `wc` 3.2x faster than uutils: the vector is a value, `lag`
says "the byte before", and the only mark is `!@`, the one thing that changes. Around
it the port reads as the Rust does but shorter: an `enum Input` with `.path(name)` and
`.stdin(named)` replaces `Input<'a>` with its `Cow<Path>` and `StdinKind`, its `title()`
and `shown()` are three-line matches, failures are `catch |e|` on the line that fails,
and no lifetime is written anywhere.

## 7. What a port costs

With uucore in place, the six small utilities took 10 to 20 minutes each, mostly reading
the Rust and the tests; their ports are 13 to 51 lines. wc took about two and a half
hours for 406 lines, most of it fidelity (count widths, `--files0-from` in its two modes,
zero-length names, quoting, `--debug`) and the vector loop. The checker's messages led
straight to each fix: of about 40 errors, all were naming clashes, missing `!` marks, or
views of owned values, each with the fix written in the message. A utility needs: the
`.ftl` run through `ftl2rig.py`, an `app()` spec, `uumain`, and a line in the
dispatcher's `run` and `UTILS`. Expect a day for the large ones (ls, sort, cp, dd) and
an hour for most.

## Files

- `coreutils/` the code (copied to `~/Data/Code/rig/compare/rig/coreutils/`)
- `ref/compare.sh RUST RIG < cases`, `ref/probe.sh`, `ref/bench.py`
- `out/tests-final-*.log` the test runs, `out/bench/run3.txt` the timings
