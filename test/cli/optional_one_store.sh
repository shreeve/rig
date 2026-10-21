# An object's optional of at most 8 bytes is written in one store of its
# full width (runtime `pack`, `OneStore`): `put`, built optimized, writes
# a `Node?` into a List's slot with no store of a single byte, where a
# flag written apart from the payload would be one.
source "$ROOT/test/cli/_lib.sh"

cat >main.rig <<'RIG'
use std.os

obj Node
  id: U32

called fun as_node(w: U32) -> Node?
  return none if w == 0
  Node(id: w)

called sub put(xs: !List[Node?], i: Int, w: U32)
  xs[i] = as_node(w)

sub main()
  xs: List[Node?] = List()
  !xs.push(none)
  !xs.push(none)
  k = U32(os.args().len)
  put(!xs, 0, k)
  put(!xs, 1, k - 1)
  print(xs[0] != none, xs[1] != none)
RIG
rig build --release -o prog main.rig >out.txt 2>err.txt || fail "rig build --release: $(cat err.txt)"
expect_eq "$(./prog)" "true false" "the program"
for f in as_node put; do
  body=$(objdump -d --no-show-raw-insn prog | awk "/[<]_*__rig_main\\.$f[>]:/ {f = 1; next} f && /^\$/ {exit} f" | sed -E 's/^ *[0-9a-f]+:[[:space:]]*//')
  [[ -n $body ]] || fail "no __rig_main.$f in the program"
  grep -qE '^(movb[[:space:]]+[^,]+,[^%]*\(|strb[[:space:]])' <<<"$body" && fail "$f stores a single byte: $body"
done
exit 0
