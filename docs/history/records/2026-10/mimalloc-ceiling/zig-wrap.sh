#!/bin/sh
# zig-wrap.sh: zig, with libc linked into every build-exe, and with
# MI=DIR also mimalloc's single-file build (DIR/src/static.c, -O3,
# NDEBUG, no C sanitizer, as its CMake release build), added at the end
# (a single program's build has one module), or just before the last -M
# (a batch's, whose last module is the runtime's).
ZIG=${REAL_ZIG:-$HOME/.local/bin/zig}
[ "$1" = build-exe ] || exec $ZIG "$@"
last=0; i=0
for a in "$@"; do
  i=$((i+1)); shift
  case $a in -M*) last=$i;; esac
  set -- "$@" "$a"
done
extra() {
  set -- -lc
  [ -n "${MI:-}" ] && set -- "$@" -fno-sanitize-c -cflags -O3 -DNDEBUG -- -I "$MI/include" "$MI/src/static.c"
  echo "$@"
}
X=$(extra)
i=0
for a in "$@"; do
  i=$((i+1)); shift
  [ $i = $last ] && set -- "$@" $X
  set -- "$@" "$a"
done
[ $last = 0 ] && set -- "$@" $X
exec $ZIG "$@"
