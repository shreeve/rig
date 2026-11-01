# A release build leaves out Zig's stack canaries, which Zig adds
# wherever libc is linked (every macOS program), and RIG_STACK_PROTECTOR=1
# keeps them: the two print the same, and only the second calls
# __stack_chk_fail. Elsewhere a program that links no libc has none
# either way, so only the first is checked there.
source "$ROOT/test/cli/_lib.sh"

cat >p.rig <<'EOF2'
called fun mix(n: Int) -> Int
  buf: [64]U8 = [64 of 0]
  for i in 0..64
    buf[i] = U8((n + i) % 251)
  s = 0
  for b in buf
    s += Int(b)
  s

sub main()
  t = 0
  for i in 0..1000
    t += mix(i)
  print(t)
EOF2

"$RIG" build --release -o plain p.rig > /dev/null 2>&1; expect_rc $? 0 "release build"
out=$(./plain); expect_eq "$out" "8022066" "release build runs"
n=$(nm -u plain 2>/dev/null | grep -c stack_chk_fail)
expect_eq "$n" "0" "release build has no stack canary"

[[ $(uname -s) == Darwin ]] || exit 0

RIG_STACK_PROTECTOR=1 "$RIG" build --release -o kept p.rig > /dev/null 2>&1; expect_rc $? 0 "release build with RIG_STACK_PROTECTOR=1"
out=$(./kept); expect_eq "$out" "8022066" "release build with canaries runs"
n=$(nm -u kept 2>/dev/null | grep -c stack_chk_fail)
expect_eq "$n" "1" "RIG_STACK_PROTECTOR=1 keeps the canaries"
