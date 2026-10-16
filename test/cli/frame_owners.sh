# timeout: 1500
# Every place Zig writes a frame of its own is a frame owner
# (docs/INTERNALS.md, "Frame owners"): a function or method, each instance
# of a generic one, a closure, a test block, a `drop` body, and `main`.
# The functions the automatic rule inlines into an owner are held to its
# account: at most 64 KiB, each counted at every call and at every copy Zig
# writes of the call. A pile of 1,300 calls of a 56 KB helper the rule
# would otherwise inline (73 MB, more than the program's stack), in each
# kind of owner and in each body that belongs to the owner around it (a
# `defer` and an `errdefer` body, a match arm, a loop over an iterator, an
# iterator's `next`), and one call in a `defer` written at 1,200 exits, must
# stop the rule from inlining it there: each program runs sanitizer-clean,
# and every owner's account (`rig check --facts=frames`) adds at most
# 64 KiB.
source "$ROOT/test/cli/_lib.sh"

helper='fun w(i: Int) -> Int
  t = [7000 of 0]
  for k in 0..7000
    t[k] = k + i
  t[i % 7000]'

# pile <indent> [lines]: calls of `w`, 10 to a line (130 lines, 1,300
# calls, by default), added to `s`.
pile() {
    local r k line
    for r in $(seq 0 $((${2:-130} - 1))); do
        line="$1s += w(i + $((r * 10)))"
        for k in $(seq 1 9); do line+=" + w(i + $((r * 10 + k)))"; done
        echo "$line"
    done
}

# The sum of a pile at i = 0: w(j) = 2j.
want=1688700

# accounts <file> [check options]: every owner's account adds at most
# 64 KiB; prints the accounts.
accounts() {
    local file=$1 facts
    shift
    facts=$(rig check "$@" --facts=frames "$file" 2>&1) || fail "facts $file: $facts"
    awk '$NF > 65536 { bad = 1 } END { exit bad }' <<<"$facts" || fail "$file: an owner's account adds more than 64 KiB: $facts"
    printf '%s' "$facts"
}

# runs <file> <expected output> <what>
runs() {
    local out
    out=$(rig run "$1" 2>&1) || fail "$3: $out"
    expect_eq "$out" "$2" "$3"
}

# A test block.
{
    echo "$helper"
    echo
    echo 'test "pile"'
    echo '  i = 0'
    echo '  s = 0'
    pile '  '
    echo '  print(s)'
} >testpile.rig
out=$(rig test testpile.rig 2>&1); expect_rc $? 0 "a pile in a test block: $out"
expect_has "$out" "$want" "a pile in a test block"
expect_has "$out" "1 passed, 0 failed" "a pile in a test block"
facts=$(accounts testpile.rig --tests)
expect_has "$facts" 'test "pile"' "a test block is an owner"
# A build that does not compile the tests (`rig run`, `rig emit`) writes
# no frame for them, so their calls bound nothing there: `main`'s one call
# is inlined.
{
    cat testpile.rig
    echo
    echo 'sub main()'
    echo '  print(w(1))'
} >testmain.rig
out=$(rig emit testmain.rig 2>&1) || fail "emit testmain: $out"
expect_has "$out" 'pub inline fn w(' "tests not compiled: w is inlined into main"
runs testmain.rig 2 "tests not compiled"
out=$(rig test testmain.rig 2>&1); expect_rc $? 0 "tests compiled: $out"
expect_has "$out" "$want" "tests compiled"
accounts testmain.rig --tests >/dev/null

# A `drop` body.
{
    echo "$helper"
    echo
    echo 'obj Res'
    echo '  n: Int'
    echo
    echo '  drop(!self)'
    echo '    i = self.n'
    echo '    s = 0'
    pile '    '
    echo '    print(s)'
    echo
    echo 'sub main()'
    echo '  r = Res(n: 0)'
    echo '  print(r.n)'
} >droppile.rig
runs droppile.rig $'0\n'"$want" "a pile in a drop body"
facts=$(accounts droppile.rig)
expect_has "$facts" '`drop`' "a drop body is an owner"

# `main`.
{
    echo "$helper"
    echo
    echo 'sub main()'
    echo '  i = 0'
    echo '  s = 0'
    pile '  '
    echo '  print(s)'
} >mainpile.rig
runs mainpile.rig "$want" "a pile in main"
accounts mainpile.rig >/dev/null

# A closure, and a closure in a closure.
{
    echo "$helper"
    echo
    echo 'fun near(i: Int) -> Int'
    echo '  f = |+i|'
    echo '    s = 0'
    pile '    '
    echo '    s'
    echo '  f()'
    echo
    echo 'fun nested(i: Int) -> Int'
    echo '  f = |+i|'
    echo '    g = |+i|'
    echo '      s = 0'
    pile '      '
    echo '      s'
    echo '    g()'
    echo '  f()'
    echo
    echo 'sub main()'
    echo '  print(near(0), nested(0))'
} >closurepile.rig
runs closurepile.rig "$want $want" "a pile in a closure"
facts=$(accounts closurepile.rig)
expect_has "$facts" 'a closure' "a closure is an owner"

# A generic function, at two instances.
{
    echo "$helper"
    echo
    echo 'fun gen[T](x: T, i: Int) -> Int'
    echo '  y = x'
    echo '  s = 0'
    pile '  '
    echo '  s'
    echo
    echo 'sub main()'
    echo '  print(gen(1, 0), gen(true, 0))'
} >genericpile.rig
runs genericpile.rig "$want $want" "a pile in a generic function"
accounts genericpile.rig >/dev/null

# A `defer` body and an `errdefer` body, which belong to the function.
{
    echo "$helper"
    echo
    echo 'error E'
    echo '  bad'
    echo
    echo 'fun later(i: Int) -> Int'
    echo '  defer'
    echo '    s = 0'
    pile '    '
    echo '    print(s)'
    echo '  i'
    echo
    echo 'fun failing(i: Int) -> Int!'
    echo '  errdefer'
    echo '    s = 0'
    pile '    '
    echo '    print(s)'
    echo '  return E.bad if i > 0'
    echo '  i'
    echo
    echo 'sub main()'
    echo '  print(later(0))'
    echo '  print(failing(1) catch 7)'
} >deferpile.rig
runs deferpile.rig "$want"$'\n0\n'"$((want + 2600))"$'\n7' "a pile in a defer and an errdefer body"
accounts deferpile.rig >/dev/null

# A `defer` body Zig writes at each of 1,200 exits: one call there is
# 1,201 calls in the frame.
{
    echo "$helper"
    echo
    echo 'fun exits(i: Int) -> Int'
    echo '  defer print(w(i))'
    for k in $(seq 1 1200); do echo "  return $k if i == $((k + 10000))"; done
    echo '  i'
    echo
    echo 'sub main()'
    echo '  print(exits(1))'
} >deferexits.rig
runs deferexits.rig $'2\n1' "a call in a defer body at 1,200 exits"
accounts deferexits.rig >/dev/null

# A match arm, and a loop over an iterator whose `next` holds a pile.
{
    echo "$helper"
    echo
    echo 'obj Count'
    echo '  n: Int'
    echo
    echo '  fun next(!self) -> Int?'
    echo '    return none if self.n > 0'
    echo '    i = self.n'
    echo '    self.n += 1'
    echo '    s = 0'
    pile '    '
    echo '    s'
    echo
    echo 'fun arm(i: Int) -> Int'
    echo '  match i'
    echo '    0'
    echo '      s = 0'
    pile '      '
    echo '      s'
    echo '    _ => 1'
    echo
    echo 'fun loop(i: Int) -> Int'
    echo '  c = Count(n: 0)'
    echo '  s = 0'
    echo '  for x in !c'
    pile '    '
    echo '    s += x'
    echo '  s'
    echo
    echo 'sub main()'
    echo '  c = Count(n: 0)'
    echo '  for x in !c'
    echo '    print(x)'
    echo '  print(arm(0), loop(0))'
} >armpile.rig
runs armpile.rig "$want"$'\n'"$want $((2 * want))" "a pile in a match arm, a loop, and an iterator's next"
accounts armpile.rig >/dev/null
exit 0
