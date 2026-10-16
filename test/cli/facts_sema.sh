# `rig check --facts=sema` checks the program, then prints the root module's
# expression facts, one per line and sorted, with no compiler ids.
source "$ROOT/test/cli/_lib.sh"

cat >main.rig <<'EOF2'
sub main()
  v: List[Int] = List()
  !v.push(1)
  print(v.len)
EOF2

"$RIG" check --facts=sema main.rig >facts.txt 2>err.txt || fail "rig check --facts=sema: $(cat err.txt)"
out=$(cat facts.txt)
expect_has "$out" 'names leaf 2:3-2:4 "v" v local' "a name's symbol"
expect_has "$out" 'types leaf 4:9-4:10 "v" List[Int]' "an expression's type"
expect_has "$out" 'scopes block 2:3-5:1' "a scope"
"$RIG" check --facts=sema main.rig >again.txt 2>/dev/null
cmp -s facts.txt again.txt || fail "two dumps of one program differ"

cat >payload.rig <<'EOF2'
enum Opt[T]
  some(v: T)
  nothing

sub main()
  t = String("t")
  match Opt.some(v: ?t)
    .some(v) => print(v)
    .nothing => pass
EOF2
"$RIG" check --facts=sema payload.rig >payload.txt 2>err.txt || fail "rig check --facts=sema payload.rig: $(cat err.txt)"
expect_has "$(cat payload.txt)" 'payload_fields leaf 8:11-8:12 "v" ?String' "a payload field's type at the instance"

# Each value that becomes an optional where it goes: `none`, and a `T`
# where a `T?` goes, which Zig lifts on its own.
cat >lift.rig <<'EOF2'
fun half(n: Int) -> Int?
  return none if n % 2 == 1
  n / 2

sub main()
  x: Int? = 4
  print(half(x ?? 0))
EOF2
"$RIG" check --facts=sema lift.rig >lift.txt 2>err.txt || fail "rig check --facts=sema lift.rig: $(cat err.txt)"
expect_has "$(cat lift.txt)" 'lifts leaf 2:10-2:14 "none" Int? from none' "the optional a none becomes"
expect_has "$(cat lift.txt)" 'lifts / 3:3-3:8 "n / 2" Int? from Int' "a result lifted into an optional"
expect_has "$(cat lift.txt)" 'lifts leaf 6:13-6:14 "4" Int? from Int' "a literal lifted into an optional"
if grep -q '"x ?? 0"' <(grep '^lifts' lift.txt); then fail "a value that goes where its own type goes is no lift"; fi

cat >bad.rig <<'EOF2'
sub main()
  print(missing)
EOF2
"$RIG" check --facts=sema bad.rig >bad.txt 2>err.txt; expect_rc $? 1 "sema of a rejected program"
[[ ! -s bad.txt ]] || fail "facts printed for a rejected program"
expect_has "$(cat err.txt)" "bad.rig:2:" "diagnostic position"
exit 0
