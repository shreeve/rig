# `rig check --facts=sema` checks the program, then prints the root module's
# expression facts, one per line and sorted, with no compiler ids.
source "$ROOT/test/cli/_lib.sh"

cat >main.rig <<'EOF2'
sub main()
  v: Vec[Int] = Vec()
  !v.push(1)
  print(v.len)
EOF2

"$RIG" check --facts=sema main.rig >facts.txt 2>err.txt || fail "rig check --facts=sema: $(cat err.txt)"
out=$(cat facts.txt)
expect_has "$out" 'names leaf 2:3-2:4 "v" v local' "a name's symbol"
expect_has "$out" 'types leaf 4:9-4:10 "v" Vec[Int]' "an expression's type"
expect_has "$out" 'scopes block 2:3-5:1' "a scope"
"$RIG" check --facts=sema main.rig >again.txt 2>/dev/null
cmp -s facts.txt again.txt || fail "two dumps of one program differ"

cat >payload.rig <<'EOF2'
enum Opt[T]
  some(v: T)
  nothing

sub main()
  t = Text("t")
  match Opt.some(v: ?t)
    .some(v) => print(v)
    .nothing => pass
EOF2
"$RIG" check --facts=sema payload.rig >payload.txt 2>err.txt || fail "rig check --facts=sema payload.rig: $(cat err.txt)"
expect_has "$(cat payload.txt)" 'payload_fields leaf 8:11-8:12 "v" ?Text' "a payload field's type at the instance"

cat >bad.rig <<'EOF2'
sub main()
  print(missing)
EOF2
"$RIG" check --facts=sema bad.rig >bad.txt 2>err.txt; expect_rc $? 1 "sema of a rejected program"
[[ ! -s bad.txt ]] || fail "facts printed for a rejected program"
expect_has "$(cat err.txt)" "bad.rig:2:" "diagnostic position"
exit 0
