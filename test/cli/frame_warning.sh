# `rig build --release` warns about a function whose frame, as the
# executable reserves it, is larger than a page though its own values fit
# in one: what is inlined into it makes the rest. The warning names the
# functions it calls that no marker keeps out of line, to mark `called`.
# Marking the callee `called`, or the function `rarely` (cold, so its
# frame costs little), leaves nothing to warn about, and so does a debug
# build, which reads no frames. The build succeeds either way.
source "$ROOT/test/cli/_lib.sh"

program() {
    cat >"$1" <<RIG
use std.os

$2fun report(n: Int) -> Int
  a = [600 of n]
  s = 0
  for x in a
    s += x
  s

$3 fun step(n: Int) -> Int
  if n > 1000000
    return report(n)
  n + 1

sub main()
  t = 0
  for i in 0..10
    t += step(i * os.args().len)
  print(t)
RIG
}

program warn.rig "" called
rig build --release -o warn warn.rig >out.txt 2>err.txt || fail "rig build --release: $(cat err.txt)"
expect_has "$(cat err.txt)" "warn.rig:10:12: warning: \`step\` reserves" "the warning names the function and where it is"
expect_has "$(cat err.txt)" "more than a page (4096 bytes), though its own values take 16: what is inlined into it holds the rest" "the warning says why"
expect_has "$(cat err.txt)" "mark it \`called\`: \`report\`" "the warning names the callee to mark"
[[ $(./warn) == 55 ]] || fail "the warned program runs"

program called.rig "called " called
rig build --release -o called called.rig >out.txt 2>err.txt || fail "rig build --release of called.rig: $(cat err.txt)"
[[ ! -s err.txt ]] || fail "a callee marked \`called\` leaves a warning: $(cat err.txt)"

program rarely.rig "" rarely
rig build --release -o rarely rarely.rig >out.txt 2>err.txt || fail "rig build --release of rarely.rig: $(cat err.txt)"
[[ ! -s err.txt ]] || fail "a \`rarely\` function is warned about: $(cat err.txt)"

rig build -o debug warn.rig >out.txt 2>err.txt || fail "rig build: $(cat err.txt)"
[[ ! -s err.txt ]] || fail "a debug build warns: $(cat err.txt)"
