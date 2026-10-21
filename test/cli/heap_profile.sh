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
grep -q "sites that held" <<<"$(RIG_HEAP_PROFILE=1 rig run --release owners.rig 2>&1)" && fail "sites are only with RIG_HEAP_PROFILE=sites"

# RIG_HEAP_PROFILE=sites adds the calls that held the most at the peak,
# each a short stack of the program's own functions.
cat >sites.rig <<'RIG'
called fun build(n: Int) -> List[Int]
  xs: List[Int] = List()
  for i in 0..n
    !xs.push(i)
  xs

sub main()
  big = build(200000)
  print(big.len)
RIG
out=$(RIG_HEAP_PROFILE=sites rig run --release sites.rig 2>&1); expect_rc $? 0 "rig run sites.rig: $out"
expect_has "$out" "sites that held the most at the peak" "the site report"
expect_has "$out" "blocks of i64, made in" "the largest site is the Int List"
expect_has "$out" "(__rig_main.zig:" "its site names a call in the program's own code: $out"
exit 0
