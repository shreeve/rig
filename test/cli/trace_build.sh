# A failure's trace from an executable `rig build` made: its places
# travel with it, so a build of the same root from changed source, into
# the same package directory, leaves the older executable's places as
# they were. And a file the program embeds is its bytes whatever they
# hold, zero bytes among them, though they look like emit's marks of a
# failure's sites.
# timeout: 300
source "$ROOT/test/cli/_lib.sh"

cat >prog.rig <<'R'
error E
  bad

fun parse(s: ?String) -> Int!
  return E.bad if s == "x"
  s.len

fun twice(s: ?String) -> Int!
  n = parse(s)!
  n * 2

sub main()
  print(twice("x")!)
R
rig build -o v1 prog.rig >/dev/null 2>&1 || fail "rig build v1"
want=$'error: E.bad\n  prog.rig:5:3\n  prog.rig:9:7\n  prog.rig:13:9'
out=$(./v1 2>&1); expect_rc $? 1 "v1 fails"
expect_eq "$out" "$want" "v1's trace"

cat >prog.rig <<'R'
error E
  bad

fun guard(s: ?String) -> Int!
  return E.bad if s == "y"
  s.len

fun parse(s: ?String) -> Int!
  return E.bad if s == "x"
  s.len

fun twice(s: ?String) -> Int!
  n = guard(s)!
  m = parse(s)!
  n * m

sub main()
  print(twice("x")!)
R
rig build -o v2 prog.rig >/dev/null 2>&1 || fail "rig build v2"
out=$(./v2 2>&1); expect_eq "$out" $'error: E.bad\n  prog.rig:9:3\n  prog.rig:14:7\n  prog.rig:18:9' "v2's trace"
out=$(./v1 2>&1); expect_eq "$out" "$want" "v1's trace after v2 was built from the same root"

# Embedded bytes with one zero byte, and with two around a place.
printf 'ab\0cd' >one.zig
printf 'ab\0x.rig:1:1\0cd' >two.zig
cat >embeds.rig <<'R'
ONE = $embed("one.zig")
TWO = $embed("two.zig")

sub main()
  print(ONE.len, TWO.len)
R
out=$(rig run embeds.rig 2>&1); expect_eq "$out" "5 15" "embedded zero bytes"
