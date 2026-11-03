# REPORT: porting uutils coreutils to Rig, what std has and what it lacks

## What std offers today

| Need | Std today | Enough? |
|---|---|---|
| argv | `os.args() -> []Static`, the raw bytes | yes |
| one env var | `os.env(name) -> Static?` | yes; there is no list of all of them and no way to set one |
| exit status | `fun main() -> Int`, `os.exit` | yes |
| stdout | `print`: buffered, written byte for byte | only when every record ends in `\n` (SPEC §17) |
| stderr | `warn` | whole lines only, so no `rm -i` prompt |
| stdin | none | stopgap `file.open("/dev/stdin")` works on macOS and Linux, but it opens a new file description, so `head`'s seek-back is lost |
| files | `read`, `write`, `append`, `open`/`create` with `File.read`/`write`, `io.copy` | no append handle, no exclusive create, no mode |
| metadata | `Stat(kind, link, size, modified)`; `Kind` is file, directory or other | no mode, uid/gid, ino/dev, nlink, blocks, atime/ctime/birth, no lstat |
| directories | `read_dir`, `mkdir(parents:)`, `remove`, `rename`, `realpath`, `exists` | no readlink, symlink, link, chmod, chown, utimes, truncate, mkfifo, mknod, umask |
| errors | 7 `FileError` members plus `failed` | none of the system's own text |
| time | `unix_ns`, `now`, `sleep` | no civil time, zones or strftime |
| bigint | parse, text, add, sub, mul, shl, shr, pow, compare | no div, rem, mod_pow, gcd, to_int |
| random, sort, maps, par, text widths | yes | yes |

What I checked by running it (`probe/`):
- Raw bytes pass through `os.args`, and `/dev/stdin` reads a pipe.
- `file.stat` takes 0.7 µs per call; Python's `os.stat` takes 0.8 µs, so the blocking pool is no speed risk.
- A Rig `yes` built on `print` plus a raw `signal(13, 0)` dies by SIGPIPE with status 141, as `test_yes` expects. It wrote 2 GB in 0.49 s, against 0.56 s for the system `yes`.

## How far raw C reaches

**Works:**
- `getuid`, `geteuid`, `getgid`, `getegid`, `getpid`, `getppid`
- `kill`, `isatty`, `umask`, `sync`, `gethostid`
- `getpriority` and `setpriority`, `alarm`
- `dup2`, `lseek` and `ftruncate` on fds 0 to 2

**Works only as a pun:** `signal(sig, 0 or 1)`, declared with an `Int` where C takes a function pointer. It runs on 64-bit systems, but the checker cannot see that the declaration is wrong. It is a stopgap, not idiomatic Rig.

**Does not work:**
- Anything that takes a path or a name, returns a pointer, or fills a struct.
- Constants that differ between systems, such as `_SC_NPROCESSORS_ONLN` (58 on macOS, 84 on Linux) and `SIGUSR1` (30 and 10). Rig has no `target.os` to choose between them.
- `File`'s fd is private, so raw C cannot `fstat` or `lseek` a file std opened.

## Non-UTF-8 names

Yes: Rust's `OsString` is simply `String` in Rig.
- Std passes paths to Zig as `[]const u8` and never checks them.
- `read_dir` names come back as the raw bytes.
- `print` writes text as it is; `\xHH` escaping applies only inside nested values.

Two caveats:
1. On macOS, APFS refuses such names ("Illegal byte sequence"), so those tests run only on Linux (pup).
2. Quoting invalid bytes as `\377` or `$'\377'` is the port's own code, built on `std.utf8`.

## What stays in the port (uucore in Rig, not std)

- **Argument parsing:** clap-compatible, with clap's exact error and usage text. It is the biggest shared piece, and every utility needs it.
- **Messages:** en-US `.ftl` files, turned into a generated `messages.rig`.
- **uucore's parser (3,707 lines) and format (3,648 lines):** printf, on a port-local decimal over bigint.
- **The rest of uucore's pure logic:** quoting_style, mode parsing, ranges, the base encodings, BSD and SysV sums, version and numeric compares, colors, backup and update control.
- **SM3:** Zig has none, so about 200 lines of Rig.
- **`shuf --random-source`:** uutils' exact draw over the source's bytes.

Module paths are read from the root file's directory (SPEC §14). So a multicall root `src/coreutils.rig` can `use uucore` and `use uu.cat.src.cat` alike. The test harness runs `coreutils NAME …` through `UUTESTS_BINARY_PATH`.

## The std additions

Name candidates are given as declaration / error as it prints / sentence. The default is first.

**1. Standard streams in std.io** (≈200 lines; needed by 53, completes 25)
- API:
  - `io.stdin() -> file.File` (fd 0, left open when dropped)
  - `io.stdout()` and `io.stderr() -> io.Out`
  - `Out.write(!@, bytes)!` goes through print's own buffer, so it stays in order with `print`; also `flush`
  - `io.copy` accepts an `Out`
  - A failed write fails with `FileError.broken_pipe` or `no_space` instead of ending the program.
- Names:
  - `stdin`/`stdout`/`stderr`
  - `input`/`output`/`errors`
  - `in`/`out`/`err` (does not work: `in` is a keyword)
- Shown as: `pub fun stdout() -> Out`; error `FileError.broken_pipe`; "`cat` copies each file to `io.stdout()`."
- Alongside it, FileError reasons:
  - New members: `not_permitted`, `read_only`, `loop`, `name_too_long`, `busy`, `cross_device`, `no_space`, `invalid`, `bad_descriptor`, `broken_pipe`, `io`, `failed(code: Int)`.
  - `file.reason(e) -> Static`, the system's own text.
  - This is the ROADMAP item "std's I/O sets", which waits for your names.

**2. std.file metadata, operations and handles** (800–1,200 lines; needed by 37, completes 19)
- `Stat` gains: `mode`, `uid`, `gid`, `nlink`, `ino`, `dev`, `rdev`, `blocks`, `block_size`, `accessed`, `changed`, `born`.
- `Kind` gains: `link`, `fifo`, `socket`, `char_device`, `block_device`.
- `stat(path, follow:)` gives lstat when `follow` is false.
- New calls: `chmod`, `chown`, `link`, `symlink`, `readlink`, `unlink`, `rmdir`, `mkdir(mode:)`, `mkfifo`, `mknod`, `set_times`, `truncate`, `access`, and `create(exclusive:, mode:, append:)`.
- On `File`: `seek`, `set_len`, `sync`, `stat`, `read_at`, `write_at`.
- Later, for some tests: openat-style dir handles, xattr and ACL, clone and copy_file_range.
- POSIX names, so no candidates.

**3. std.digest** (250–350 lines; completes 9)
- Thin bindings to Zig's `std.crypto` (MD5, SHA-1, SHA-2, SHA-3, BLAKE2b, BLAKE3) and `std.hash.crc`, which already has `CRC-32/CKSUM`.
- API: `digest.Sha256.new()`, `!h.add(bytes)`, `h.finish()`, `digest.Blake2b.new(bytes: n)`, `digest.crc32_cksum`.
- Rig has no Zig-backed types yet, so each hasher's state lives in a private bytes buffer or a handle slot.
- Zig's CRC is a table loop, while Rust folds with PMULL/PCLMUL, so `cksum`'s benchmark loses unless the shim folds too.
- Names: `digest` / `hash` (clashes with the built-in `Hasher` and the archived `std.hash`) / `crypto`.
- Shown as: `pub obj Sha256`; `DigestError.bad_length`; "`sha256sum` feeds each file to a `digest.Sha256`."

**4. bigint division** (250–400 lines of Rig)
- Adds `div`, `rem`, `div_rem`, `mod_pow`, `gcd`, `to_int`, `text(base:)`.
- Needed by `factor` (tests go past 2^128) and `expr`.

**5. std.os additions** (≈150 lines; completes 6)
- `vars()`, `set_env`/`unset_env`, `system()` (uname), `hostname()`, `cores(online:)`
- `pid`/`uid`/`euid`/`gid`/`egid`, `groups()`, `umask()`, `limit(:path_max)`
- Plus `target.os`.

**6. std.user** (400–600 lines; needed by 18)
- `user.by_name`, `by_id`, `group_by_id`, `groups_of`, `login()`, `sessions()` (utmpx).
- Names: `user` / `users` (also a utility's name) / `account`.
- Shown as: `pub fun by_name(name: ?String) -> User?!`; `UserError.failed`; "`id` looks each name up with `user.by_name`."

**7. std.date** (1,500–2,500 lines of Rig, buildable now)
- TZif files and POSIX `TZ` strings, civil time, GNU strftime, `date -d` parsing.
- Names: `date` / `calendar` / extend `std.time` (`time.civil`).
- Shown as: `pub fun at(ns: Int, zone: ?Zone) -> Date`; `DateError.invalid`; "`ls -l` prints each file's time with `date.format`."

**8. std.regex** (2,000–3,000 lines of Rig, buildable now)
- A Pike VM, plus a backtracker for back-references; BRE, ERE and the Rust crate's syntax.
- Names: `regex` / `re` / `pattern`.
- Shown as: `regex.compile(pat, syntax: .basic) -> Regex!`; `RegexError.unmatched_paren(at: 4)`; "`csplit` cuts at each line `regex.compile` matches."

**9. std.tty** (300–450 lines)
- `is_terminal`, `size`, `name`, `mode`/`set_mode` (termios), `raw`.
- Names: `tty` / `console` / `term` (too close to `std.terminal`, the emulator).
- Shown as: `pub fun size(fd: Int) -> Size?`; `TtyError.not_terminal`; "`ls` asks `tty.size(1)` for its width."

**10. std.process and std.signal** (600–900 lines)
- API:
  - `process.spawn`, `exec` (flushes print's buffer first), `Child.wait` (a fallible waiting point), `Child.kill`
  - `signal.reset(.pipe)`, `ignore`, `send`, a channel to watch signals, and names and numbers
- `spawn` must use `posix_spawn` because the runtime runs several threads.
- Names: `process`/`signal` / `proc`/`sig` / `run`/`signal`.
- Shown as: `pub fun spawn(argv: []?String, ...) -> Child!`; `ProcessError.not_found`; "`timeout` starts the command with `process.spawn` and sends it `signal.term`."

**11. std.disk** (250–350 lines)
- `disk.stat(path) -> Space?!` and `disk.mounts()`.
- Names: `disk` / `mount` / extend `std.file` (`file.space`).

**Blocked or later:** SELinux; `stdbuf`; ICU collation and locale data (DUCET tables are megabytes; candidate names `collate`, `locale`).

## Risks for tests and benchmarks

- **SIGPIPE.** Rig's runtime exits with status 0 when stdout's reader closes. `yes`, `seq`, `cat`, `tee`, `sort` and `env` (19 cases) expect death by SIGPIPE. The raw pun works now; `signal.reset(.pipe)` is the clean form.
- **Error text** is checked in 61 test files ("No such file or directory" alone appears 216 times).
- **Speed.** Expected losses are `cksum`'s CRC and `cp` without clone or copy_file_range. `print` and `file.stat` keep up.
- **System differences** (errno text, signal numbers, utmpx layouts, stat fields) need std to hide them, or `target.os`.