# coreutils wave 1: running log

Rig port: ~/Data/Code/rig/compare/rig/coreutils. Tests: uutils' own, unchanged
(tests/run.sh: CI=true, `--release`; DEBUG=1: debug build, RIG_SANITIZE=1). Logs:
wave1/all-release-*.log, all-debug-*.log. Benches: bench.py, arms Rust, GNU
(prefix:/opt/homebrew/bin/g), Rig, through tools/low, fastest of 20 (bench4.txt;
base16/shuf/b64-encode rerun in bench5.txt). Load average 3.5 to 9 during benches
(other agents). Lines: sloc.py code lines of the utility's own files (Rust
src/uu/X/src, Rig src/uu/X/*.rig); shared uucore code apart.
The logs and bench outputs are on pup in
`/zfs/trig-pup/records-data/rust-ports/coreutils/wave1/`.

"Rust fails too": none of these; per-util.md lists no Rust failure for them.

| utility | tests passed/total (release; sanitized debug same) | bench Rig vs Rust | bench Rig vs GNU | lines Rust/Rig | notes |
|---|---|---|---|---|---|
| unlink | 6/6 | no bench | | 33/16 | a directory refused by stat first; EPERM text (macOS): std.target has no OS |
| sleep | 55/55 | no bench | | 60/20 | parse_time on uucore/num.rig |
| hostid | 3/3 | no bench | | 58/21 | /etc/hostid, else gethostid() (raw); uutils' DNS fallback unreachable |
| rmdir | 14/14 | no bench | | 165/73 | file.remove removes files too: stat first (TOCTOU) |
| sync | 12/12 | no bench | | 261/36 | -d/-f do a full sync(): no fd for fdatasync/syncfs |
| dircolors | 18/18 | no bench | | 427/203 | glob matcher, color tables in uucore |
| seq | 101/105 (+1 ignored) | 35-100% faster (5 benches) | 47-96% faster | 478/225 | 3 caret diagnostics (ariadne not ported); SIGPIPE-ignored (runtime gap) |
| sum | 12/12 | no bench | | 181/67 | |
| paste | 23/23 | no bench | | 332/129 | |
| comm | 65/66 (+1 ignored) | no bench | | 390/111 | locale collation (no ICU in std) |
| expand | 45/45 | 83-90% faster | 3.4-8x faster | 377/220 | |
| tsort | 23/23 | 38-179% faster | 3-7x faster | 460/168 | |
| fold | 100/100 | 42-61% faster | 4-6x faster | 620/354 | |
| unexpand | 46/46 | 87-103% faster | 15-19x faster | 559/291 | |
| uniq | 40/40 | 35-91% faster | 1-23% faster | 718/282 | |
| printf | 149/155 (+1 ignored) | no bench | | 158/82 (+756 format engine in uucore) | 6 caret diagnostics |
| shuf | 72/72 (+1 ignored) | 9-82% faster (5 benches) | 22-174% faster | 630/411 | SHA3-256 + ChaCha12 for --random-seed |
| base32 | 16/16 | (via basenc) | | 742/449 | base_common + encoding |
| base64 | 23/23 | encode 14% faster, decode 45-48% faster | 92% faster encode | 14/9 | |
| basenc | 37/37 | base16 equal to 6% faster | 77-129% faster | 75/29 | |
| tr | 177/183 | no bench | | 1229/437 | 6 caret diagnostics |
| cut | 67/72 | 22-49% faster | 1.2-3x faster (newline-delim 1.9x slower) | 1189/448 | 5 caret diagnostics |
| join | 51/55 | 83-124% faster | 2x faster | 1030/395 | 2 caret diagnostics, 2 locale (collation, decimal point) |
| fmt | 46/46 (+2 ignored) | no bench | | 1430/596 | Knuth-Plass in f32 as uutils |

Totals (release and sanitized debug alike, 31 utilities incl. the seven before; no sanitizer report, no leak): 1393 passed, 26 failed, 6 ignored of
1425. Of the 26: 22 caret diagnostics (uucore diagnostics/ariadne, not ported), 3 locale
(ICU collation, locale decimal point), 1 SIGPIPE-ignored detection (runtime).

## Gaps found
- std/runtime: no OS in std.target (unlink's EPERM vs EISDIR, SIGBUS number); FileError
  drops errno ("(os error N)" text mapped by hand); std.file.remove removes files and
  directories alike (rmdir/unlink must stat first); no fd access (fdatasync, syncfs,
  O_NONBLOCK, isatty); no locale data or collation (comm/join/sort under a locale);
  whether the parent ignored SIGPIPE is lost; the runtime's fault handler swallows one
  SIGSEGV/SIGBUS sent by kill (uucore disables Rust's; the port resets them).
- compiler: `rig check` accepts an error-set member with fields written as
  `.member(field: v)` where a parameter of the error type is expected; the emitted Zig
  fails ("no field named ... in struct rig.runtime.ErrorValue").
  Repro: bugs/error-member-shorthand/main.rig.
- language frictions: a String's bytes cannot be written in place (a List[U8] plus
  `read[U64]`/`push[U64](keep:)` copies them out); no Static from String (new argv words
  are built from slices of old ones or literal tables); module-wide name clashes across
  a directory's files.

## Speed work
- base64 decode was 9.5x slower: a linear search of the alphabet per symbol. A 256-entry
  value table and four symbols to three bytes at once: now 45-48% faster than Rust.
- base64/base16 encode: three bytes to one U32 push, a byte-pair table four bytes at a
  time, and line wrapping straight from the encoded block (one copy, not four).
- seq -f: values up to 17 digits step as Ints at one scale (same values, same text):
  21% slower to 35% faster.
- shuf: numbers formatted into a stack array and copied out a word at a time; a file
  read whole at its size.
- seq's integer fast path (uutils' fast_inc) keeps the number in a List[U8] and copies
  it out with read[U64]/push[U64](keep:), since a String's bytes cannot be written.

## Batch 3: caret diagnostics, numfmt, split, sort (2026-10-31)

Rig at the owner's checkout (pre-#798/#799), the stopgap io and raw SIGPIPE.
Logs: wave1/all-release-9.log, all-debug-9.log (RIG_SANITIZE=1, no reports);
benches bench6.txt (numfmt, split; first sort pass) and bench8.txt (sort after the
speed work below), fastest of 20, load 6-30 (other agents; bench8 at 6).

**Totals, 34 utilities:** 1948 passed, 36 failed, 6 ignored of 1990, release and
sanitized debug identical. The 22 caret-diagnostic failures all pass.

| utility | tests | bench Rig vs Rust | lines Rust/Rig | notes |
|---|---|---|---|---|
| caret diagnostics (uucore) | 22/22 snippet tests | - | 548/158 | ariadne's one layout: one line, one span, one label, a help; no colors. Wired into printf, seq, tr, cut, join, numfmt, split, sort |
| numfmt | 200/203 | 29-137% faster (11 benches) | 1940/996 | 3 fr_FR locale tests: no locale data (decimal comma, U+202F grouping) |
| split | 129/132 | 15-2196% faster (5 benches) | 1956/654 | 3 --filter tests: std cannot start a shell |
| sort | 204/230 | see below | 4562/1174 | in-memory only (no ext sort, temp files, threads) |

New uucore: diagnostics.rig, size.rig (parse_size, allow list/default unit/`b`),
ranges.rig (Range::from_list with spans), quoting.c_single, charmap.grouping_separator,
printf.fixed/round_digits public, numcmp.numeric_order, args: App.error_code, option alias.

sort failures (26): ICU collation/UTF-8 locale order (6), locale month names fr/hu/ja (4),
French translations and clap localization (5), colored help/errors (6), temporary
files never written: -T missing dir, --compress-program, private tmp files, SIGINT
cleanup, tmp dir symlink (5).

sort benches (bench8): faster than Rust on 17 of 29 rows (whole-line byte sorts 52-1260%
faster). Slower rows: -f 268%, -d 283%, -n 204%, -g 118%, -k2 69%, 2M-line C sort 207%,
shared prefix 72%, numeric utf8 109%, merge 2-5%. Rust sorts on 10 threads; against
`--parallel=1` Rust the gap is 10-20% (-f, -d, -n, -g) and 2x for -k2. Done: eight-byte
compare, records sorted in place of indexes, a float shortcut for -g (two floats that
differ order the decimals the same way), whole-line fast paths for -f/-d/-i. Not done:
sorting on tasks. 10 "rig differs" rows are UTF-8 collation; check_sorted_utf8 exits 1
where ICU calls the file sorted.

Gaps recorded: no Static from a String (bugs/no-static-from-string: split's `-d200a4`,
sort's `-tX` and `+1 -2` worked around); no locale data (numfmt fr, sort collation,
months); no process spawn (split --filter, sort --compress-program); no inode identity
(split's "would overwrite input" by realpath, missing hard links and stdin); no
getrlimit (sort --batch-size limits).

## Switch to Rig main 7e932e66d (#798 io streams and file.reason, #799 on_broken_pipe)

RIG=~/Data/Code/worktrees/rig/port-rig/bin/rig from here on.
- uucore/io.rig: `-` opens `io.stdin()`; Records keeps one read buffer (`!@more.clear()`).
  `stat("-")` still asks /dev/stdin: std has no stat of a descriptor.
- uucore/util.rig: stdout is `io.stdout()`; Out.flush also flushes it, so a failed
  write is reported by the utility (the dispatcher flushes at the end).
- uucore/error.rig: `describe`/`strerror` are `file.reason`; `errno` covers the new
  members (macOS numbers).
- uucore/signals.rig: `restore_sigpipe` is `os.on_broken_pipe(.die)`, from main, as
  uucore's main does for every utility. numfmt reuses its read buffer.

Tests (all-release-10.log, all-debug-10.log): 1948 passed, 36 failed, 6 ignored,
release and RIG_SANITIZE identical to before, test for test; no sanitizer reports.
seq's test_sigpipe_ignored_reports_write_error still fails: uucore keeps SIGPIPE
ignored when the parent ignored it, and the Rig runtime replaces the disposition at
start without keeping it, so `.die` always applies (bugs/sigpipe-parent-ignored).

Benches: bench9 (Rust, GNU, new Rig; 85 rows, load 6): 73 faster than Rust, 11 slower
(the sort rows above, and base16). bench10 (old vs new Rig, interleaved, load 5):
73 rows faster, 12 slower; above 2% on a >10 ms bench only base16_encode_to_dev_null
(12.55 -> 21.19 ms, 69% slower) and base16_encode_to_file (15.62 -> 24.20 ms, 55%
slower). That is the new rig, not the switch: the pre-switch source built with it is
as slow, and the emitted Zig is the same (bugs/base16-slower-on-main). Under 10 ms:
uniq_check_chars/(10000,512) 8% slower, sort_long_line 5%, tsort_tree_dag 4%.
