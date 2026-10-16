# std.utf8's bulk readers never read past the end of a string: every
# string here ends at the last byte of a page whose next page is
# inaccessible, so a read past its end stops the program. `ascii_end`
# from every cursor, and `rune_count`, `utf16.unit_count`,
# `utf16.byte_index`, and `is_valid` of every suffix, run clean in a debug
# build and with --release, on strings of 0 to 200 bytes that end in
# ASCII, in a rune of two to four bytes, in a first byte whose sequence
# is cut short, and in a continuation byte. Then a read one byte past
# the end is shown to be caught, by the guard page and, in a debug build
# with RIG_SANITIZE=1, by the sanitizer at the end of a String whose
# capacity is its length. `RIG_STD` adds `std.guard`, the Zig that maps
# the pages.
# timeout: 300
source "$ROOT/test/cli/_lib.sh"

mkdir lib
cp "$ROOT"/std/*.rig "$ROOT"/std/*.zig lib/

cat >lib/guard.rig <<'EOF'
extern zig "guard.zig"
  # A copy of `s` whose last byte is the last of a page; the page after it
  # is inaccessible. It is never freed.
  pub fun guarded(s: ?String) -> Static
  # A String of the bytes of `s` with no room for more.
  pub fun exact(s: ?String) -> String
  # The byte just past the end of `s`, read without a test.
  pub fun past_end(s: ?String) -> Int
EOF

cat >lib/guard.zig <<'EOF'
const std = @import("std");
const rig = @import("../runtime.zig");

pub fn guarded(s: []const u8) []const u8 {
    const page = std.heap.pageSize();
    const size = std.mem.alignForward(usize, s.len, page) + page;
    const mem = std.posix.mmap(null, size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0) catch @panic("mmap");
    const guard = @intFromPtr(mem.ptr) + size - page;
    if (std.posix.errno(std.posix.system.mprotect(@ptrFromInt(guard), page, .{})) != .SUCCESS) @panic("mprotect");
    const start: [*]u8 = @ptrFromInt(guard - s.len);
    @memcpy(start[0..s.len], s);
    return start[0..s.len];
}

pub fn exact(s: []const u8) rig.String {
    var t: rig.String = .{};
    t.list.ensureTotalCapacityPrecise(rig.defaultAllocator(), s.len) catch @panic("out of memory");
    t.list.appendSliceAssumeCapacity(s);
    return t;
}

pub fn past_end(s: []const u8) i64 {
    const p: *const volatile u8 = @ptrFromInt(@intFromPtr(s.ptr) + s.len);
    return p.*;
}
EOF

cat >main.rig <<'EOF'
use std.guard
use std.utf16
use std.utf8

ENDINGS = ["", "\xc3\xa9", "\xe4\xb8\xad", "\xf0\x9f\x98\x80", "\xc3", "\xe4\xb8", "\xf0\x9f\x98", "\x80", "\xff"]

fun scan(s: ?String, i: Int) -> Int
  k = i
  while k < s.len and s[k] < 0x80
    k += 1
  k

fun reference(s: ?String, wide: Bool) -> Int
  n = 0
  i = 0
  while i < s.len
    d = utf8.rune_after(s, i)
    n += 2 if wide and d.size == 4 else 1
    i += d.size
  n

sub main()
  checked = 0
  wrong = 0
  t = String()
  for len in 0..201
    for e in ENDINGS
      !t.clear()
      while t.len + e.len < len
        !t.add("\u{4e2d}" if t.len % 37 == 36 and t.len + 3 + e.len <= len else "x")
      !t.add(e)
      s = guard.guarded(t)
      for i in 0..s.len + 1
        checked += 1
        wrong += 1 if utf8.ascii_end(s, i) != scan(s, i)
        units = utf16.unit_count(s[i..])
        wrong += 1 if utf8.rune_count(s[i..]) != reference(s[i..], false) or units != reference(s[i..], true)
        wrong += 1 if utf16.byte_index(s[i..], units) != s.len - i
        _ = utf8.is_valid(s[i..])
  print(checked, wrong)
EOF

cat >past.rig <<'EOF'
use std.guard

sub main()
  print(guard.past_end(guard.guarded("abc")))
EOF

cat >past_sanitized.rig <<'EOF'
use std.guard

sub main()
  t = guard.exact("abc")
  print(guard.past_end(t))
EOF

expected=$(RIG_STD="$PWD/lib" rig run main.rig 2>&1) || fail "debug run: $expected"
[[ $expected == *" 0" ]] || fail "debug: $expected"
RIG_SANITIZE=1 RIG_STD="$PWD/lib" rig run main.rig >sanitized.txt 2>&1 || fail "sanitized run: $(cat sanitized.txt)"
expect_eq "$(cat sanitized.txt)" "$expected" "sanitized run"
RIG_STD="$PWD/lib" rig build --release -o prog main.rig || fail "release build"
out=$(./prog 2>&1); expect_rc $? 0 "release run: $out"
expect_eq "$out" "$expected" "release run"

# The guard page stops a read one byte past the end, in both builds.
RIG_NO_CRASH_REPORT=1 RIG_STD="$PWD/lib" rig run past.rig >past.txt 2>&1 && fail "debug read past the end exited 0: $(cat past.txt)"
RIG_STD="$PWD/lib" rig build --release -o past past.rig || fail "release build of past.rig"
RIG_NO_CRASH_REPORT=1 ./past >past.txt 2>&1 && fail "release read past the end exited 0: $(cat past.txt)"
# And the sanitizer stops it at the end of a String.
RIG_NO_CRASH_REPORT=1 RIG_SANITIZE=1 RIG_STD="$PWD/lib" rig run past_sanitized.rig >past.txt 2>&1 && fail "sanitized read past the end exited 0"
expect_has "$(cat past.txt)" "access past the end of a 3-byte block" "the sanitizer's report"
exit 0
