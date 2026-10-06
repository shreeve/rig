# `rig check --facts=storage` checks the program, then prints the hidden
# storage emit makes for the root module, one per line in source order,
# and the emitted Zig names each of those locations.
source "$ROOT/test/cli/_lib.sh"

cat >main.rig <<'EOF2'
struct S
  n: Int
  m: Int

  fun f(?self, a: Int, b: Int) -> Int
    self.n + a * b

fun mk -> S
  S(n: 1, m: 2)

fun half(n: Int) -> Int!
  n / 2

fun both(a: Int, b: Int) -> Int
  a + b

sub main!
  print(mk().f(b: half(2)!, a: half(6)!))
  for i in 0..3
    print(i)
  a = [1, 2, 3]
  a[half(2)!] = 7
  print(both(b: half(4)!, a: half(6)!), a)
EOF2

"$RIG" check --facts=storage main.rig >facts.txt 2>err.txt || fail "rig check --facts=storage: $(cat err.txt)"
out=$(cat facts.txt)
expect_has "$out" 'receiver call 18:9-18:13 "mk()" owned call' "a call's receiver"
expect_has "$out" 'argument propagate 18:19-18:27 "half(2)!" owned call' "a reordered method argument"
expect_has "$out" 'range_start for 19:3-' "a range loop's counter"
expect_has "$out" 'index propagate 22:5-22:13 "half(2)!" owned assignment' "an assignment's index"
expect_has "$out" 'argument propagate 23:17-23:25 "half(4)!" owned call' "a reordered argument"
"$RIG" check --facts=storage main.rig >again.txt 2>/dev/null
cmp -s facts.txt again.txt || fail "two dumps of one program differ"
"$RIG" emit main.rig >main.zig 2>err.txt || fail "rig emit: $(cat err.txt)"
expect_has "$(cat main.zig)" '__rig_recv_' "the receiver's storage"
expect_has "$(cat main.zig)" '__rig_ix_' "the index's storage"
"$RIG" run main.rig >run.txt 2>err.txt || fail "rig run: $(cat err.txt)"
expect_has "$(cat run.txt)" '4' "the program's output"

cat >bad.rig <<'EOF2'
sub main()
  print(missing)
EOF2
"$RIG" check --facts=storage bad.rig >bad.txt 2>err.txt; expect_rc $? 1 "storage of a rejected program"
[[ ! -s bad.txt ]] || fail "facts printed for a rejected program"
exit 0
