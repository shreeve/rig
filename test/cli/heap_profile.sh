# RIG_HEAP_PROFILE=1 at build makes a program report, at exit, what owned
# its memory at its peak: live bytes by the type each block holds, largest
# first. A List's buffer is its element's, text is `u8`, and a List freed
# before the peak is not in it. Without the flag nothing is reported.
source "$ROOT/test/cli/_lib.sh"

cat >owners.rig <<'RIG'
obj Node
  id: Int
  name: String

sub main()
  nodes: List[Node] = List()
  for i in 0..20000
    !nodes.push(Node(id: i, name: String("node number ", i)))
  gone: List[U16] = List()
  for i in 0..1000
    !gone.push(U16(i))
  <gone
  big: List[Int] = List()
  for i in 0..300000
    !big.push(i)
  print(nodes.len, big.len)
RIG

for mode in "" "--release"; do
  out=$(RIG_HEAP_PROFILE=1 rig run $mode owners.rig 2>&1); expect_rc $? 0 "rig run $mode owners.rig: $out"
  expect_has "$out" "20000 300000" "the program runs ($mode)"
  expect_has "$out" "rig: heap profile:" "the report ($mode)"
  first=$(grep -A2 "rig: heap profile:" <<<"$out" | tail -1)
  expect_has "$first" " i64" "the largest owner is the Int List ($mode): $out"
  expect_has "$out" "__rig_main.Node" "the Node List is an owner ($mode)"
  expect_has "$out" " u8" "text is u8 ($mode)"
  grep -q " u16$" <<<"$out" && fail "a List freed before the peak is not in it ($mode): $out"
done

out=$(rig run owners.rig 2>&1); expect_rc $? 0 "rig run owners.rig"
grep -q "heap profile" <<<"$out" && fail "no report without RIG_HEAP_PROFILE: $out"
exit 0
