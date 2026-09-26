# A program that runs off its stack stops there: the frame that
# overflows never writes into memory mapped below the stack. Zig probes
# the stack only on x86; on aarch64 macOS the guard below the stack is
# one page, and once the address space below fills, the system maps
# memory right next to it. This program fills that space with shared
# mappings, then a child recurses with a 1 MB frame until it overflows;
# the parent looks for the child's bytes in the mappings.
source "$ROOT/test/cli/_lib.sh"

[[ $(uname -s) == Darwin && $(uname -m) == arm64 ]] || exit 0

cat >clash.rig <<'EOF2'
extern fun pthread_self() -> U64
extern fun pthread_get_stackaddr_np(t: U64) -> U64
extern fun pthread_get_stacksize_np(t: U64) -> U64
extern fun mmap(addr: U64, len: U64, prot: I32, flags: I32, fd: I32, off: I64) -> U64
extern fun memchr(p: U64, c: I32, n: U64) -> U64
extern fun fork() -> I32
extern fun waitpid(pid: I32, status: U64, options: I32) -> I32

fun stack_bottom() -> U64
  raw
    t = pthread_self()
    pthread_get_stackaddr_np(t) - pthread_get_stacksize_np(t)

# Shared memory (MAP_SHARED | MAP_ANON), readable and writable, wherever
# the system puts it.
fun map(len: U64) -> U64
  raw
    mmap(0, len, 3, 0x1001, -1, 0)

fun holds(p: U64, len: U64, byte: I32) -> Bool
  raw
    memchr(p, byte, len) != 0

fun spawn() -> I32
  raw
    fork()

sub wait(pid: I32)
  raw
    waitpid(pid, 0, 0)

fun dive(depth: Int) -> Int
  a: [1000000]U8 = [165; 1000000]
  a[depth % 7] = 165
  if depth < 0
    return 0
  Int(a[depth % 7]) + dive(depth + 1)

sub main()
  bottom = stack_bottom()
  addrs = Vec[U64]()
  lens = Vec[U64]()
  for len in [U64(16777216), 1048576, 65536]
    while true
      p = map(len)
      if p == 18446744073709551615 or p > bottom
        break
      !addrs.push(p)
      !lens.push(len)
  pid = spawn()
  if pid == 0
    print(dive(0))
  wait(pid)
  dirty = 0
  for i in 0..addrs.len
    if holds(addrs[i], lens[i], 165)
      dirty += 1
  print(addrs.len > 0, dirty)
EOF2

out=$("$RIG" run clash.rig 2>/dev/null); expect_eq "$out" "true 0" "mappings the overflowing child wrote into"

# A program that cannot reserve the space below its stack (here a
# preloaded library maps a page there first) stops before it runs.
cat >occupy.zig <<'EOF2'
const std = @import("std");
extern "c" fn pthread_get_stackaddr_np(std.c.pthread_t) *anyopaque;
extern "c" fn pthread_get_stacksize_np(std.c.pthread_t) usize;
fn occupy() callconv(.c) void {
    const self = std.c.pthread_self();
    const bottom = @intFromPtr(pthread_get_stackaddr_np(self)) - pthread_get_stacksize_np(self);
    _ = std.c.mmap(@ptrFromInt(bottom - (16 << 10) - (32 << 20)), 16 << 10, .{}, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0);
}
export const init linksection("__DATA,__mod_init_func") = [_]*const fn () callconv(.c) void{&occupy};
EOF2
"${ZIG:-zig}" build-lib occupy.zig -dynamic -lc -femit-bin=occupy.dylib || fail "build occupy.dylib"
printf 'sub main()\n  print(42)\n' >hi.rig
"$RIG" build -o hi hi.rig || fail "build hi"
expect_eq "$(./hi)" "42" "a program with the space free"
DYLD_INSERT_LIBRARIES=$PWD/occupy.dylib ./hi >out.txt 2>err.txt; expect_rc $? 1 "a program with the space taken"
expect_eq "$(cat out.txt)" "" "stdout of a program that cannot guard its stack"
expect_eq "$(cat err.txt)" "rig: cannot reserve the stack guard below the main stack" "its message"
exit 0
