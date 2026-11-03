# Queue row 25: four std additions for the coreutils port, and a runtime bug

**Approved by the owner, 2026-10-31 about 10:00** ("Confirmed", in Rig - Rust (fork)): (a) `target.os: Os`, a built-in enum as `Arch`; (b) `file.unlink`, `file.rmdir`, `file.remove` unchanged; (c) `f.sync()`, `f.sync_data()`, `f.sync_fs()`, `os.sync()`, F_FULLFSYNC on macOS, `f.is_terminal()`, `file.open(p, wait: false)`, `File.fd` private; (e) SIGILL and SIGFPE as #808; (f) `os.on_broken_pipe(.inherit)`.

Design only, against Rig main at 7e932e66d (`~/Data/Code/worktrees/rig/port-rig`).
Nothing here is built. The owner picks every name; each section gives the
default first. (d), locale, is out of scope.

| Part | Default | Alternatives | Where it lands |
|---|---|---|---|
| (a) the target's OS | `target.os: Os` | `target.platform: Platform`; `target.system: System` (collides with Trig) | std/target.rig/.zig, a built-in enum `Os` beside `Arch` (resolve, sema, emit, facts, runtime) |
| (b) remove one kind | `file.unlink(path) -> Bool!`, `file.rmdir(path) -> Bool!` | `remove_file`/`remove_dir`; `remove(path, kind:)` | std/file.rig/.zig |
| (c) sync | `f.sync()!`, `f.sync_data()!`, `f.sync_fs()!`, `os.sync()` | `f.sync(data: true)`; `f.fsync()`/`f.fdatasync()` | std/file.rig/.zig, std/os.rig/.zig |
| (c) isatty | `f.is_terminal() -> Bool` | `f.is_tty()`; `f.isatty()` | std/file.rig/.zig |
| (c) O_NONBLOCK | `file.open(path, wait: false)` | `block: false`; `nonblock: true` | std/file.rig/.zig |
| (e) kill -SEGV swallowed | a fault handler tells a sent signal from a fault and dies of a sent one | — | src/runtime.zig |

Mantras this leans on (docs/design/mantras.md): dissolve rather than patch
(no nonblocking File state at all, see (c)); actions are verbs (`unlink`,
`rmdir`, `sync`); a test reads as a question (`is_terminal`); avoid a word other
languages disagree on (`remove`, see (b)); one classifier per fact (one
`sentSignal` for both handlers, see (e)).

---

## (a) The operating system, in std.target

### 1. What is missing, and who needs it

`std.target` has `arch` and nothing else (STD.md "std.target": "The operating
system and the CPU's features are not built yet"). Code cannot choose by
system, so the port hard-codes macOS:

- `src/uucore/signals.rig`: `SIGBUS: I32 = 10`, "10 on macOS and the BSDs, 7 on
  Linux, which std.target cannot yet tell". Every signal number that differs
  (SIGBUS, SIGUSR1/2, SIGCHLD, SIGSTOP...) has the same problem, as do
  `sysconf` names (`_SC_NPROCESSORS_ONLN` is 58 on macOS, 84 on Linux).
- `unlink`: "EPERM on macOS and the BSDs, EISDIR on Linux, which std.target
  cannot yet tell apart". (b) removes this one need, but the expected error
  in a test of (b) still differs by system, and the test uses `target.os`.
- The panel's "System differences" risk (errno text, utmpx layouts, stat
  fields) and `arch`/`uname` (arm64 versus aarch64) name it too.

### 2. Design

Exactly as `arch` is built (SPEC §3 "The target", `src/resolve.zig:5053`): a
built-in enum whose variants are all of Zig's, lowered to Zig's own type, so
no system needs mapping and each name means what it means to Zig.

```rig pending
# std/target.rig
extern zig "target.zig"
  # The target's processor architecture...
  pub arch: Arch
  # The operating system the program is compiled for, one of the built-in
  # enum `Os`'s variants (`.macos`, `.linux`, `.freebsd`, `.windows`, ...).
  pub os: Os
```

```zig
// std/target.zig
pub const os = builtin.os.tag;
// src/runtime.zig, beside `pub const Arch = std.Target.Cpu.Arch;`
pub const Os = std.Target.Os.Tag;
```

Compiler: the ten places that name `arch_sym_id` get an `os_sym_id` twin:
`resolve.zig:5053` (the symbol and its variants from
`@typeInfo(std.Target.Os.Tag)`), `sema.zig:3879, 10305, 12692` (the field, "is a
built-in enum", one type across modules), `facts.zig:146, 171`,
`emit.zig:592, 7965` (the `__rig_text_Os` table that prints `.macos`). Nothing
new in kind: `Os` is checked as `Arch` is, both branches of a choice kept, and
rejected where Rig needs the value when it checks (an array length, a module
constant's arithmetic), with `Arch`'s messages.

Variants are Zig 0.17's `std.Target.Os.Tag`: `freestanding, other, ...,
linux, ..., freebsd, netbsd, openbsd, ..., ios, maccatalyst, macos, tvos,
visionos, watchos, windows, ..., wasi, ...`. Two (`@"3ds"`, `@"switch"`) are
not Rig names: they stay in the enum, print as `.3ds`/`.switch`, and are
matched only by `_`. Nothing a program would test.

Errors: none; it is a compile-time constant.

macOS: `.macos`. Linux: `.linux` (glibc or musl alike; the ABI would be a
later `target.abi`). No family test (`is_darwin`, `is_bsd`) now: `== .linux`
covers both systems the port runs on; one can come later if a program needs it.

### 3. Names

| | Default `os: Os` | `platform: Platform` | `system: System` |
|---|---|---|---|
| Declaration | `pub os: Os` | `pub platform: Platform` | `pub system: System` |
| Error | ``no variant `darwin` on enum `Os` `` | ``no variant `darwin` on enum `Platform` `` | ``no variant `darwin` on enum `System` `` |
| Prose | "`target.os` is the operating system the program is compiled for." | "`target.platform` is the system the program is compiled for." | "`target.system` is the system the program is compiled for." |
| Note | pairs with `arch: Arch`; `target.os` beside the module `std.os` reads fine, since both are always qualified | Node and Python call the OS "platform", but to many it means arch plus OS | **rejects Trig**: `Os`-style built-ins are reserved (`types-misc-1` "arch reserved"), and Trig declares `pub obj System` (src/execute/compile.rig:36) |

Others: Zig `builtin.os.tag` (`.macos`, `.linux`); Rust `cfg!(target_os =
"macos")`, `std::env::consts::OS == "macos"`; Go `runtime.GOOS == "darwin"`;
Python `sys.platform == "darwin"`, `platform.system() == "Darwin"`. Rig takes
Zig's variant names, as `Arch` does.

### 4. Tests

- test/cli/std_target.sh: `print(target.os)` is `.macos` when `uname -s` is
  Darwin, `.linux` on Linux; emit keeps both branches of `X = 7 if target.os ==
  .linux else 10`; `pub const os: rig.Os = ` in std's emitted target module.
- test/rig/types-misc-1.rig.test, beside the `Arch` cases:
  `fail "os reserved", "3:6: `Os` is a reserved built-in nominal name and cannot
  be redefined"`; `fail "os variants", "no variant `darwin` on enum `Os`"`, and
  `Int(target.os)`, `Os.from_int(1)`, `$variants(Os)` rejected as for `Arch`;
  `test "target os is a variant", "true"` with `print(target.os == .macos or
  target.os == .linux)`.
- Doc example, STD.md "std.target" (the "not built yet" line goes):

```rig pending
use std.target

SIGBUS = 7 if target.os == .linux else 10

sub main()
  print(target.os == .macos or target.os == .linux, SIGBUS == 7 or SIGBUS == 10)
```

```output
true true
```

### 5. What changes for existing programs

`Os` becomes a reserved built-in name: a program that declares a type `Os`
is rejected. None does in Rig's std, tests, examples, Trig, loco, or the port
(searched for `obj|enum|error|type|api|union Os`). The release notes still
list the rule, and Trig gets its one-line note.

---

## (b) Removing a file or a directory, not either

### 1. What is missing, and who needs it

`file.remove(path)` unlinks, and on failure rmdirs (std/file.zig `removeHere`):
C's `remove(3)` and Go's `os.Remove`. A utility that must refuse the other
kind stats first, which is a race (the path may change between the stat and
the remove) and re-derives the system's error by hand:

- `rmdir` (src/uu/rmdir/rmdir.rig `remove_one`): stats, returns
  `.not_directory` for a file or a link without a trailing `/`, then removes.
- `unlink` (src/uu/unlink/unlink.rig): stats, and for a directory returns the
  hand-written `"Operation not permitted"`, macOS's text, wrong on Linux.
- `rm` (rm.rs `remove_file`/`remove_dir`, both `fs::`): `rm` without `-d`
  must not remove a directory, `rm -d` takes an empty one; `rm -r`'s walk
  calls each by kind. `shred -u` and `split`/`csplit`'s clean-up remove files.

### 2. Design

Two calls, each one system call, so the system decides and names the
failure, and nothing is stat'ed:

```rig pending
# Remove the file at `path`, whatever its kind but a directory: a symbolic
# link itself, never what it names. `true`, or `false` when nothing was there.
# A directory fails: `FileError.is_directory` on Linux, `not_permitted` on
# macOS, each the system's own reason.
pub fun unlink(path: ?String) -> Bool!

# Remove the empty directory at `path`: `true`, or `false` when nothing was
# there. A file fails with `FileError.not_directory`, a directory that holds
# entries with `not_empty`.
pub fun rmdir(path: ?String) -> Bool!
```

Both in the `extern zig "file.zig"` block, on the pool like `remove`:

```zig
pub fn unlink(path: []const u8) Error!bool { return pool(bool, unlinkHere, .{path}); }
fn unlinkHere(path: []const u8) FileError!bool {
    var buf: [std.Io.Dir.max_path_bytes:0]u8 = undefined;
    const z = try terminated(path, &buf);
    while (true) switch (posix.errno(sys.unlink(z))) {
        .SUCCESS => return true,
        .NOENT => return false,
        .INTR => {},
        else => |e| return errnoFailure(e),
    };
}
// rmdir: the same with sys.rmdir(z).
```

`remove` stays, and its doc says it is either, as C's and Go's are. Its two
halves become `unlinkHere` and `rmdirHere`, so the three share one call each.

`false` only for ENOENT, as `remove` gives it. ENOTDIR is not "nothing there"
here: `rmdir("f")` and `rmdir("f/x")` both give ENOTDIR, and `rmdir` the
utility reports "Not a directory" for both, as GNU does. So both fail with
`not_directory`, which is also what `remove("f/x")` gives today.

Errors (all existing members): `not_directory`, `is_directory`,
`not_permitted`, `not_empty`, `denied`, `busy` (a mount point), `invalid`
(`rmdir(".")`), `read_only`, `loop`, `name_too_long`, `io`, `failed`.

What each system does, measured with Python's `os.unlink`/`os.rmdir` (the bare
calls) on the Mac and on pup:

| Call | macOS | Linux |
|---|---|---|
| `unlink(dir)` | `not_permitted` (EPERM) | `is_directory` (EISDIR) |
| `unlink("dir/")` | `not_permitted` (EPERM), as `unlink(dir)`: measured on macOS 27.0.1 by #823 | `is_directory` |
| `rmdir(file)`, `rmdir("file/x")` | `not_directory` | `not_directory` |
| `rmdir(link to dir)` | `not_directory` | `not_directory` |
| `rmdir("link/")` | **removes the directory the link names** | `not_directory` |
| `rmdir(full)` | `not_empty` (ENOTEMPTY 66) | `not_empty` (39) |
| `rmdir(".")` | `invalid` | `invalid` |

Correction (#823, measured on macOS 27.0.1): `unlink("dir/")` fails with
`not_permitted` (EPERM), as `unlink(dir)` does, and Python's `os.unlink`
agrees. The design's earlier `false` (ENOENT) row was wrong; the port's
expected unlink output follows the measured result.

### 3. Names

| | Default `unlink` / `rmdir` | `remove_file` / `remove_dir` | `remove(path, kind:)` |
|---|---|---|---|
| Declaration | `pub fun unlink(path: ?String) -> Bool!`, `pub fun rmdir(path: ?String) -> Bool!` | `pub fun remove_file(path: ?String) -> Bool!`, `pub fun remove_dir(...)` | `pub fun remove(path: ?String, kind: Kind? = none) -> Bool!` |
| Error | `rmdir: failed to remove 'f': Not a directory` from `FileError.not_directory` | the same | the same |
| Prose | "`rmdir` removes an empty directory, as `mkdir` makes one; `unlink` removes anything else." | "`remove_dir` removes an empty directory; `remove_file` anything else." | "`remove(p, kind: .directory)` removes only a directory." |
| Note | POSIX's and Python's (`os.unlink`, `os.rmdir`, `Path.unlink`, `Path.rmdir`), Perl's and PHP's, every one meaning the same; `rmdir` pairs with std's `mkdir`; they are the utilities' own names | Rust's (`fs::remove_file`, `fs::remove_dir`); reads `file.remove_file`, and "file" there means "not a directory", where `Kind.file` means a regular file | one call, but `Kind.file` is a regular file while unlink removes links, FIFOs, sockets, devices too, so `kind: .file` says less than it does; and `.other` means nothing here |

Others: Zig `Dir.deleteFile`, `Dir.deleteDir`; Go has only `os.Remove`
(either) and `syscall.Unlink`/`Rmdir`; C `unlink(2)`, `rmdir(2)`, `remove(3)`
(either). Python's `os.remove` is unlink, C's `remove` is either: `remove` is
a word languages disagree on, which is why the default keeps it for "either"
and gives the narrow calls the names everyone agrees on.

### 4. Tests

- test/rig/std-file.rig.test (changes nothing: each call fails):

```rig pending
use std.target

test "file unlink and rmdir refuse the other kind", "FileError.not_directory true"
  # rmdir(2) takes only a directory; unlink(2) never takes one, with each
  # system's own reason.
  a = file.rmdir("AGENTS.md") catch |e| e
  b = file.unlink("examples") catch |e| e
  want = FileError.is_directory if target.os == .linux else FileError.not_permitted
  print(a, b == want)
```

  (sketch: the exact shape of a caught error as a value follows the existing
  cases in that file, which print through a `show(e)` helper.)
- test/cli/std_file_ops.sh, which makes and removes files: `unlink` of a file,
  a symbolic link (the link goes, its target stays), a FIFO, and a missing
  path (`true true true false`); `rmdir` of an empty directory, a missing path,
  a full one (`not_empty`), a link to a directory (`not_directory`); `rmdir`
  of `link/`, whose answer is each system's (the table above); a read-only
  directory's entry (`denied`).
- Doc example, STD.md "std.file", after `remove`'s row:

```rig pending
use std.file

sub main()!
  file.write("out/rm/f", "x", parents: true)!
  _ = file.rmdir("out/rm/f") catch |e|
    print(e)
    false
  print(file.unlink("out/rm/f")!, file.rmdir("out/rm")!, file.rmdir("out/rm")!)
```

```output
FileError.not_directory
true true false
```

### 5. What changes for existing programs

Nothing: two new names in `std.file`, and `remove` keeps its meaning. The
port's `rmdir` and `unlink` lose their stats (and the race), and `unlink`
its hand-written EPERM.

---

## (c) Descriptor calls on a File: sync, is_terminal, an open that does not wait

### 1. What is missing, and who needs it

A `File`'s descriptor is private (`fd: Int`, "Its field is the runtime's"),
and std offers nothing on it but read, write, and flush. The port needs:

- **fsync/fdatasync/syncfs.** `sync -d FILE` (fdatasync, `sync_data` in Rust),
  `sync -f FILE` (syncfs, Linux only), plain `sync` (sync(2), raw `extern sub
  sync()` in the port today; `-d` and `-f` fall back to it); `dd
  conv=fsync|fdatasync`, `oflag=sync`; `shred` (fsync after each pass).
- **isatty.** `tty -s` and `tty` (stdin), `ls` (stdout: columns, colors,
  `--hyperlink=auto`, quoting), `rm -i`/`-I` (stdin, "presume input tty"),
  `tail` (stdin), `cat` (stdin is interactive), `wc` (whether to warn on
  stdin), `more`, `stty`.
- **O_NONBLOCK.** Every use in the Rust utilities is the same pattern: open
  with O_NONBLOCK so the open does not wait for a FIFO's writer, then clear
  the flag with `fcntl(F_SETFL)` so reads block as usual. `sync`
  (`open_and_reset_nonblock`, and its check that each file opens), `tail
  --pid` (`open_file(path, use_nonblock_for_fifo)`). GNU's sync does the same.
  (cat's only fcntl use is `F_GETFL` for `O_APPEND` on stdout, in its "input
  file is output file" check, which also needs `fstat`'s dev and ino: that is
  the panel's `File.stat`, REPORT item 2, not this row.)

### 2. Design

#### sync

```rig pending
pub obj File
  ...
  # Write the file's bytes and what the file system records of it (size,
  # times) out to the device, and wait until the device has them: Unix's
  # fsync, or on macOS `F_FULLFSYNC`, which also asks the drive to empty its
  # cache. On stdout, what `print` buffered is written out first.
  pub sub sync(!@)!
    sync_fd(@fd, 0)!

  # The same for the bytes, and what reading them back needs (the size), but
  # not the times: fdatasync. On macOS it is `sync`.
  pub sub sync_data(!@)!
    sync_fd(@fd, 1)!

  # Write out everything waiting for the file system that holds this file:
  # Linux's syncfs. Other systems have no such call, and write out every file
  # system, as `os.sync()` does.
  pub sub sync_fs(!@)!
    sync_fd(@fd, 2)!
```

```rig pending
# std/os.rig: write out everything every file system holds for its devices:
# sync(2). It does not fail.
pub sub sync()
```

Lowering (std/file.zig): `sync_fd(fd, how)` flushes `print`'s buffer when
`fd == 1` (`rig.net.fileFlush`), then runs on the pool as a fallible waiting
point, as `File.read` does, on a duplicate of the descriptor
(`rig.net.duplicate`, made `pub`), closed by its drop, so a task that stops
waiting and drops the File cannot leave the pool syncing a reused number. The
call, looping on EINTR:

| `how` | Linux | macOS |
|---|---|---|
| 0 `sync` | `fsync` | `fcntl(F_FULLFSYNC)`; on EINVAL, ENOTSUP, ENOTTY or EBADF (a pipe gives EBADF, an SMB mount ENOTSUP) `fsync`, whose reason is the answer |
| 1 `sync_data` | `fdatasync` | as `sync` (Rust's `sync_data` on Apple is `F_FULLFSYNC` too) |
| 2 `sync_fs` | `syncfs` | `sync()`, which cannot fail |

`os.sync()` lowers to `std.posix.sync()`; it can take seconds, so it runs on
the pool too, as a waiting point that cannot fail with a FileError (so
`os.sync()!` fails only with `task.Stop`; or, if the owner prefers a plain
`sub`, it runs on the task's thread and blocks it).

Errors (existing members): `io` (EIO), `no_space` (ENOSPC), `failed` (EDQUOT,
anything else), `invalid` (EINVAL: a pipe, a socket, a terminal, `/dev/null`
on Linux; measured on both systems: `fsync` of a pipe is EINVAL on both),
`bad_descriptor`, `read_only` (EROFS from some special files). A file open to
read can be synced on both systems (measured).

#### is_terminal

```rig pending
  # Whether this file is a terminal: isatty. A standard stream asks about the
  # stream the program was started with: `io.stdout().is_terminal()` is how
  # `ls` decides to print columns.
  pub fun is_terminal(?@) -> Bool
    terminal_fd(@fd)
```

Lowering: `std.Io.File{ .handle = fd }.isTty(rig.io()) catch false`, as the
runtime already asks of stdout (`stdout_is_tty`, src/runtime.zig:7258). One
ioctl, on the task's own thread like a standard stream's write: not a waiting
point, and no `!`: ENOTTY and EBADF (a closed stream) are both "no". It lends
the File as a view (`?@`), since it changes nothing.

#### an open that does not wait

```rig pending
# The file at `path` to read, or `none` when nothing is there. With
# `wait: false` the open does not wait for a FIFO's writer, or a device to be
# ready; the reads after it wait as any read does (a FIFO with no writer
# reads as its end, 0 bytes).
pub fun open(path: ?String, wait: Bool = true) -> File?!
  if open_fd(path, wait)! as fd
    return File(fd: fd)
  none
```

Lowering (`openHere`): with `wait == false`, `openat` with `.NONBLOCK = true`
added to `{ RDONLY, CLOEXEC }`, then `fcntl(F_GETFL)` and `fcntl(F_SETFL,
flags without O_NONBLOCK)`; a failure there closes the descriptor and fails
with its reason. Both systems: macOS and Linux open a FIFO for reading with
O_NONBLOCK at once, with or without a writer (measured: then reads give 0
bytes, its end, on both).

**Why no nonblocking File.** A File's reads run on the blocking pool, and a
task waits for them; concurrency comes from tasks. A descriptor left
nonblocking would make a read fail with EAGAIN, which FileError has no member
for (`failed`), to give a program something it already has. So std never
leaves a File nonblocking: the one thing O_NONBLOCK is used for in the
utilities, an open that does not hang on a FIFO, becomes the option, and
the flag never reaches Rig. Nothing to set on an open file, so no `fcntl`
in std.

### 3. Names

**sync.**

| | Default `sync` / `sync_data` / `sync_fs` | `sync(data: true)` | `fsync` / `fdatasync` / `syncfs` |
|---|---|---|---|
| Declaration | `pub sub sync(!@)!`, `pub sub sync_data(!@)!`, `pub sub sync_fs(!@)!` | `pub sub sync(!@, data: Bool = false, fs: Bool = false)!` | `pub sub fsync(!@)!` ... |
| Error | `sync: error syncing 'f': Input/output error` from `FileError.io` | the same | the same |
| Prose | "`dd conv=fdatasync` calls `!out.sync_data()` before it ends." | "`dd conv=fdatasync` calls `!out.sync(data: true)`." | "`dd conv=fdatasync` calls `!out.fdatasync()`." |
| Note | verbs; Rust's `sync_data`; `sync` alone is Go's `File.Sync` | one method, but two Bools make four states for three calls | the system's names, but Rig spells out (`is_terminal`, not `isatty`) |

Others: Rust `File::sync_all`, `File::sync_data` (F_FULLFSYNC on Apple), no
syncfs (rustix); Go `File.Sync` (F_FULLFSYNC on darwin), no datasync;
Python `os.fsync(fd)`, `os.fdatasync(fd)` (not on macOS), `os.sync()`; Zig
`File.sync` (fsync), `posix.fdatasync`, `posix.syncfs`, `posix.sync`.

**is_terminal.**

| | Default `is_terminal` | `is_tty` | `isatty` |
|---|---|---|---|
| Declaration | `pub fun is_terminal(?@) -> Bool` | `pub fun is_tty(?@) -> Bool` | `pub fun isatty(?@) -> Bool` |
| Message | `tty: not a tty` printed when `not io.stdin().is_terminal()` (the utility's own text) | the same | the same |
| Prose | "`ls` prints columns when `io.stdout().is_terminal()`." | "... when `io.stdout().is_tty()`." | "... when `io.stdout().isatty()`." |
| Note | a question with `is_`, as `text.is_digit`; the word std.terminal uses; Rust's | shorter; jargon most readers know | C's and Python's spelling, no `_` |

Others: Rust `IsTerminal::is_terminal`; Python `f.isatty()`, `os.isatty(fd)`;
Go `golang.org/x/term.IsTerminal(fd)` (std has none); Zig `File.isTty`.

**open without waiting.**

| | Default `wait: false` | `block: false` | `nonblock: true` |
|---|---|---|---|
| Declaration | `pub fun open(path: ?String, wait: Bool = true) -> File?!` | `..., block: Bool = true` | `..., nonblock: Bool = false` |
| Error | `sync: error opening 'p': Permission denied` from `FileError.denied` | the same | the same |
| Prose | "`tail --pid` opens a FIFO with `wait: false`, so a writer that never comes cannot hold it." | "... with `block: false` ..." | "... with `nonblock: true` ..." |
| Note | Rig's own word: the task does wait at a waiting point, the open just does not wait for the writer | plain, but suggests the File stays nonblocking | the flag's name, which suggests nonblocking reads, which it does not give |

Others: Rust `OpenOptions::custom_flags(O_NONBLOCK)` then `fcntl_setfl`;
Go `os.OpenFile(p, O_RDONLY|syscall.O_NONBLOCK, 0)`; Python `os.open(p,
O_RDONLY|O_NONBLOCK)` then `os.set_blocking(fd, True)`; Zig `posix.openat`
with `.NONBLOCK = true` then `fcntl`.

### 4. Tests

- test/rig/std-file.rig.test (changes nothing):

```rig pending
use std.io

test "file sync of a file open to read", "true"
  f = file.open("examples/hello.rig")! ?? return
  (!f).sync()!
  (!f).sync_data()!
  (!f).sync_fs()!
  true

test "file is_terminal of a file", "false false"
  f = file.open("examples/hello.rig", wait: false)! ?? return
  print(f.is_terminal(), io.stdin().is_terminal())
```

  (the suite runs each case with stdin from `/dev/null` or a pipe; if not, the
  second answer moves to the cli script.)
- test/cli/std_io.sh: under a pseudo-terminal (`script -q /dev/null ./t` on
  macOS, `script -qc ./t /dev/null` on Linux) `io.stdout().is_terminal()` and
  `io.stdin().is_terminal()` are `true`; piped, `false`; with stdin closed
  (`<&-`), `false`. `!io.stdout().sync()!` with stdout redirected to a file
  writes the buffered `print` first and succeeds; piped, it fails with
  `FileError.invalid` on both systems.
- test/cli/std_file_ops.sh: `mkfifo p`; `file.open("p", wait: false)` returns
  at once (the script's `timeout 5` catches a hang), reads 0 bytes, and the
  File's flags afterwards lack O_NONBLOCK (a writer started after the open
  writes `hi`, and a blocking read gets it); `file.open("p")` without the
  option waits, and a `time.within(100 * time.MS, ...)` around it fails with
  `task.Stop.timeout`.
- Doc example, STD.md "std.file", after the File table:

```rig pending
use std.file
use std.io

sub main()!
  file.write("out/sync/f", "kept\n", parents: true)!
  if file.open("out/sync/f", wait: false)! as f
    (!f).sync_data()!
    print(f.is_terminal())
  print(io.stdout().is_terminal())
```

```output
false
false
```

### 5. What changes for existing programs

Nothing rejected: `open` gains a parameter with a default, `File` and
`std.os` gain names. The port's `sync` drops its raw `extern sub sync()` and
gains real `-d` and `-f` on Linux.

---

## (e) A SIGSEGV or SIGBUS sent by kill is swallowed once

### Cause

`src/runtime.zig:6880` `onOverflow`, the handler `onOwnStack` installs for
SIGSEGV and SIGBUS in every build mode (6692), and `src/runtime.zig:6487`
`Sanitizer.onFault` (RIG_SANITIZE=1), take every SEGV or BUS for a fault. For
one outside the guard (6887) or not in the sanitizer's spans (6490), each puts
back the handlers it replaced and **returns**, counting on the faulting
instruction to run again and fault into them. A signal from `kill(2)` has no
faulting instruction: the return resumes the program, and the signal is gone.

Measured on the Mac with a `rig build --release` program that sleeps 3 s:

| Sent | Status | Output |
|---|---|---|
| one `kill -SEGV` | 0 | `survived` |
| two `kill -SEGV` | 134 (SIGABRT) | `Segmentation fault at address 0x0`, a trace: the second reaches Zig's handler, which aborts |
| one `kill -BUS` | 0 | `survived` |

A C program dies with 139 (SIGSEGV) or 138 (SIGBUS on macOS; 135 on Linux),
which `test_sleep_stops_after_sigsegv`/`_sigbus` require (`signal_is`). The
swallowed signal also uninstalls the overflow handler, so a later stack
overflow loses `error: rig: stack overflow`. The port works around it with
raw `signal(11, SIG_DFL)` and `signal(10, SIG_DFL)` (src/uucore/signals.rig
`restore_fault_signals`), which also turns off that message. Rust's own
handler has the same bug, which is why uucore removes it.

### What tells a sent signal from a fault

- **Linux: `si_code`, exactly.** A sent signal has `si_code <= 0` (SI_USER 0,
  SI_QUEUE -1, SI_TKILL -6, and the rest); a fault has a SEGV_*/BUS_* code
  above 0, or SI_KERNEL 0x80 (an x86-64 general-protection fault). Measured on
  pup: `kill` gives code 0 and an `si_addr` of `uid << 32 | pid`
  (0x3e8003f672c), `raise` gives -6, a null store gives 1. That address could
  even land in the guard, so the check must come before the guard test.
- **macOS: not `si_code`.** XNU fills SEGV and BUS from the thread's last
  exception: `kill -SEGV` gives SEGV_ACCERR (2), `kill -BUS` BUS_ADRALN (1), and
  a null store also 2 (measured). The thread's own state does tell: on arm64
  the ESR in the signal's machine context (`uc_mcontext->__es.__esr`) has
  exception class 0x15 (a system call) for a signal delivered as the thread
  leaves the kernel, and 0x24 (data abort) or 0x20 (instruction abort) for a
  real fault. But the ESR is the thread's *last* exception: a `kill` that
  arrives while the thread is taking ordinary page faults shows 0x24 and the
  FAR of a page it just touched (measured: `si3.c`, a loop touching fresh pages,
  `esr 0x9200004b`, FAR mapped and writable). So an abort class counts as a
  fault only if the FAR is still not accessible for that access (read; write
  when ESR's WnR bit 6 is set; execute for 0x20), asked of
  `mach_vm_region`; an alignment fault (DFSC 0x21, or class 0x22/0x26) always
  counts. x86-64 macOS: the same rule on `__es.__trapno` (14 page fault, with
  `__err` bit 1 for a write; 13; 17) and `__faultvaddr`, not measured (no Intel
  Mac here).

### The fix

One classifier, called first by both handlers:

```zig
/// Whether `sig` was sent (kill, raise, sigqueue) rather than raised by
/// the instruction the thread was running.
fn sentSignal(info: *const std.posix.siginfo_t, ctx: ?*anyopaque) bool {
    if (builtin.target.os.tag == .linux) return info.code <= 0;
    if (builtin.target.os.tag.isDarwin()) return !darwinFault(ctx); // ESR/FAR, above
    return false; // elsewhere: today's behaviour
}

/// End the program by `sig`, as its default action does: no message, no
/// trace, no flush, as a C program killed by it.
fn dieOf(sig: std.posix.SIG) noreturn {
    const dfl: std.posix.Sigaction = .{ .handler = .{ .handler = std.posix.SIG.DFL }, .mask = std.posix.sigemptyset(), .flags = 0 };
    std.posix.sigaction(sig, &dfl, null);
    var set = std.posix.sigemptyset();
    std.posix.sigaddset(&set, sig);
    std.posix.sigprocmask(std.posix.SIG.UNBLOCK, &set, null);
    std.posix.raise(sig) catch {};
    std.process.abort();
}
```

`onOverflow` begins `if (sentSignal(info, ctx)) dieOf(sig);`, and
`Sanitizer.onFault` takes `sig` and `ctx` and begins the same. A real fault
takes the path it takes today. `darwinFault` reads the machine context
through a small extern struct of the runtime's own (Zig's
`signal_ucontext_t`, std/debug/cpu_context.zig:2363, is private): on arm64 the
mcontext pointer sits at offset 48, FAR at 0 of it, ESR at 8. About 40 lines
in all, half of them macOS's.

`dieOf` sets SIG_DFL rather than handing on to Zig's handler: that one turns
the signal into "Segmentation fault at address 0x0" and SIGABRT, which is right
for a fault and wrong for a signal someone sent.

Smallest step if the macOS part waits: the Linux line alone (exact), with
macOS keeping today's behaviour. But the bug was found on the Mac, so the
default is both.

**Siblings.** In debug and `--release` builds Zig's own handler holds SIGILL
and SIGFPE, and turns `kill -ILL`/`-FPE` into the same "... at address 0x0"
and SIGABRT (134 for 132/136). The class fix installs Rig's handler on those two
as well, with the same classifier (on macOS the abort classes differ: 0x00 and
0x0E for ILL, 0x2C for FPE). Open question 3.

### Tests

- test/cli/fault_signal.sh (new; `# builds: shared`), in debug, `--release`,
  `--release=fast`, and debug with `RIG_SANITIZE=1`: a program that sleeps 5 s,
  sent `kill -SEGV` after 0.3 s, ends with status 139 and no output; the same
  with `kill -BUS`, 138 on macOS and 135 on Linux (`kill -l BUS` gives the
  number); a program that sends itself SIGSEGV with raw `kill(getpid(), 11)`
  and then prints `survived` prints nothing and ends 139. On macOS, one more
  program that touches fresh pages in a loop while the script sends the
  signal: the stale-ESR case.
- The cases that must stay as they are: test/cli/stack_guard.sh (a real
  overflow still says `error: rig: stack overflow`, 134),
  test/rig/runtime-stack-guard.rig.test, and the sanitizer's use-after-free
  and past-the-end cases (a real fault in a span still prints its message
  first). Linux runs on pup.
- Docs: SPEC §1's stack paragraph (SPEC.md:650) gains "A SIGSEGV or SIGBUS
  another process sends ends the program by that signal, as its default
  action does." INTERNALS "The message" says the handler tells a sent signal
  from a fault, and how. The port drops `restore_fault_signals`.

What changes: a program sent SIGSEGV or SIGBUS now dies of it. None could
rely on surviving it, since a second one aborts.

---

## Open questions for the owner

1. **Names**, defaults in each table: (a) `target.os: Os`; (b) `file.unlink`
   and `file.rmdir`; (c) `f.sync`, `f.sync_data`, `f.sync_fs`, `os.sync`,
   `f.is_terminal`, `file.open(path, wait: false)`.
2. **macOS sync means "on the disk":** `sync` and `sync_data` use
   `F_FULLFSYNC` there, as Rust and Go do, and as the Rust utilities do (so
   the port behaves the same). It is much slower than `fsync` (the drive
   empties its cache). Default: yes.
3. **SIGILL and SIGFPE** in the same fix (the sibling class)? Default: yes,
   for Linux in the same change; macOS's after its exception classes are
   measured, like SEGV's were.
4. **No public descriptor.** Making `File.fd` readable would let raw code do
   the rest (fstat, fcntl getfl, ttyname, ioctl), at the price of raw code
   able to close what the File will close again. Default: no; each need
   becomes a std call, as here, and `File.stat` comes with the panel's
   item 2.

## Evidence

Probes in `design/probes/` (`si.c`, `si2.c`, `si3.c`, `fs.py`,
`nap.rig`), run on the Mac (arm64, Darwin 27) and on pup (x86-64 Linux):
kill and fault `si_code`/ESR/FAR, unlink/rmdir errnos, sync calls on files,
pipes and `/dev/null`, a FIFO opened with O_NONBLOCK and then cleared, and the
Rig program that survives `kill -SEGV`.
