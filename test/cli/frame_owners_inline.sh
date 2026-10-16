# timeout: 1500
# frame_owners.sh for calls of functions marked `inline`: a marked
# function's body lands in the frame of each call of it, so its values
# count in the account of the owner the call is in (its marked part), at
# every copy Zig writes of the call, and what the automatic rule inlines
# into it lands there too, held to that owner's 64 KiB. In each kind of
# owner and each body that belongs to the owner around it (a `defer` body
# at 1,200 exits, an `errdefer` body, a `drop` body, a match arm, an
# iterator's `next` as the loop calls it, `main`, a closure in a closure,
# and an instance of another module's generic function), one call of `m`
# (16 KB of values) must show in the account's marked part, and a pile of
# 1,300 calls of `g`, which calls a 56 KB helper the rule would otherwise
# inline (73 MB, more than the program's stack), must stop the rule from
# inlining the helper there: each program runs sanitizer-clean, and every
# owner's account adds at most 64 KiB through the rule.
source "$ROOT/test/cli/_lib.sh"

helper='fun w(i: Int) -> Int
  t = [7000 of 0]
  for k in 0..7000
    t[k] = k + i
  t[i % 7000]

inline fun m(i: Int) -> Int
  t = [2000 of i]
  t[i % 2000]

inline fun g(i: Int) -> Int
  w(i) + 1'

# pile <indent>: 1,300 calls of `g`, 10 to a line, added to `s`.
pile() {
    local r k line
    for r in $(seq 0 129); do
        line="$1s += g(i + $((r * 10)))"
        for k in $(seq 1 9); do line+=" + g(i + $((r * 10 + k)))"; done
        echo "$line"
    done
}

# The sum of a pile at i = 0: g(j) = 2j + 1.
want=1690000

# accounts <file> [check options]: every owner's account adds at most
# 64 KiB through the rule (its last column); prints the accounts.
accounts() {
    local file=$1 facts
    shift
    facts=$(rig check "$@" --facts=frames "$file" 2>&1) || fail "facts $file: $facts"
    awk '$NF > 65536 { bad = 1 } END { exit bad }' <<<"$facts" || fail "$file: an owner's account adds more than 64 KiB: $facts"
    printf '%s' "$facts"
}

# marked <facts> <label> <least> <what>: the account of an owner named
# `label`, the largest of them, has at least `least` in its marked part
# ("L:C label bytes reach marked auto"; a label has spaces).
marked() {
    local got
    got=$(awk -v want="$2" '{ l = $2; for (i = 3; i <= NF - 4; i++) l = l " " $i; if (l == want) print $(NF - 1) }' <<<"$1" | sort -n | tail -1)
    [[ -n $got ]] || fail "$4: no account of $2 in: $1"
    ((got >= $3)) || fail "$4: $2's marked part is $got, less than $3"
}

# runs <file> <expected output> <what>
runs() {
    local out
    out=$(rig run "$1" 2>&1) || fail "$3: $out"
    expect_eq "$out" "$2" "$3"
}

# A `defer` body Zig writes at each of 1,200 exits: one call of `m` there
# is 1,201 copies of its values in the frame.
{
    echo "$helper"
    echo
    echo 'fun exits(i: Int) -> Int'
    echo '  defer print(m(i))'
    for k in $(seq 1 1200); do echo "  return $k if i == $((k + 10000))"; done
    echo '  i'
    echo
    echo 'sub main()'
    echo '  print(exits(1))'
} >deferexits.rig
runs deferexits.rig $'1\n1' "an inline call in a defer body at 1,200 exits"
facts=$(accounts deferexits.rig)
marked "$facts" '`exits`' $((1201 * 16000)) "a defer body at 1,200 exits"

# An `errdefer` body, a `drop` body, and a match arm.
{
    echo "$helper"
    echo
    echo 'error E'
    echo '  bad'
    echo
    echo 'fun failing(i: Int) -> Int!'
    echo '  errdefer'
    echo '    s = m(i)'
    pile '    '
    echo '    print(s)'
    echo '  return E.bad if i == 0'
    echo '  i'
    echo
    echo 'obj Res'
    echo '  n: Int'
    echo
    echo '  drop(!self)'
    echo '    i = self.n'
    echo '    s = m(i)'
    pile '    '
    echo '    print(s)'
    echo
    echo 'fun arm(i: Int) -> Int'
    echo '  match i'
    echo '    0'
    echo '      s = m(i)'
    pile '      '
    echo '      s'
    echo '    _ => 1'
    echo
    echo 'sub main()'
    echo '  print(failing(0) catch 7)'
    echo '  r = Res(n: 0)'
    echo '  print(arm(0))'
} >bodies.rig
runs bodies.rig "$want"$'\n7\n'"$want"$'\n'"$want" "inline calls in an errdefer body, a drop body, and a match arm"
facts=$(accounts bodies.rig)
marked "$facts" '`failing`' 16000 "an errdefer body"
marked "$facts" '`drop`' 16000 "a drop body"
marked "$facts" '`arm`' 16000 "a match arm"

# An iterator's `next`, marked `inline`, as the loop over it calls it:
# its values, and the helper the rule inlines through it, land in the
# function with the loop.
{
    echo "$helper"
    echo
    echo 'obj Count'
    echo '  n: Int'
    echo
    echo '  inline fun next(!self) -> Int?'
    echo '    return none if self.n > 0'
    echo '    i = self.n'
    echo '    self.n += 1'
    echo '    s = m(i)'
    pile '    '
    echo '    s'
    echo
    echo 'fun loop(i: Int) -> Int'
    echo '  c = Count(n: i)'
    echo '  s = 0'
    echo '  for x in !c'
    echo '    s += x'
    echo '  s'
    echo
    echo 'sub main()'
    echo '  print(loop(0))'
} >iterpile.rig
runs iterpile.rig "$want" "an inline iterator's next"
facts=$(accounts iterpile.rig)
marked "$facts" '`loop`' 16000 "an iterator's next, called by the loop"

# `main`, and a closure in a closure.
{
    echo "$helper"
    echo
    echo 'fun nested(i: Int) -> Int'
    echo '  f = |+i|'
    echo '    h = |+i|'
    echo '      s = m(i)'
    pile '      '
    echo '      s'
    echo '    h()'
    echo '  f()'
    echo
    echo 'sub main()'
    echo '  i = 0'
    echo '  s = m(i)'
    pile '  '
    echo '  print(s, nested(0))'
} >mainpile.rig
runs mainpile.rig "$want $want" "inline calls in main and in a closure in a closure"
facts=$(accounts mainpile.rig)
marked "$facts" '`main`' 16000 "main"
marked "$facts" 'a closure' 16000 "a closure in a closure"

# An instance of another module's generic function, made here: its
# `inline` calls land in it at this instance, which its module's frame
# check never sees.
mkdir -p across
cat >across/lib.rig <<'RIG'
fun w(i: Int) -> Int
  t = [7000 of 0]
  for k in 0..7000
    t[k] = k + i
  t[i % 7000]

inline fun m[T](x: T, i: Int) -> Int
  t = [2000 of x]
  t.len - 2000 + i

inline fun g(i: Int) -> Int
  w(i) + 1
RIG
{
    echo 'pub fun gen[T](x: T, i: Int) -> Int'
    echo '  s = m(x, i)'
    pile '  '
    echo '  s'
} >>across/lib.rig
cat >across/main.rig <<'RIG'
use lib

sub main()
  print(lib.gen(1, 0), lib.gen(true, 0))
RIG
runs across/main.rig "$want $want" "inline calls in another module's generic function, at instances made here"
accounts across/main.rig >/dev/null
exit 0
