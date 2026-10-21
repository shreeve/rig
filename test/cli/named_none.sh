# An object that names its none (`none id == 0`) has an optional the size
# of the object, so a `Node?` passes in one register and its test is one
# compare: `has`, built optimized, reads no memory and is at most two
# instructions besides its frame and its return. The named none is the
# object's niche, so an object holding a `Node` takes it too, and an
# optional of a `Node?` takes a flag: the none is one value.
source "$ROOT/test/cli/_lib.sh"

cat >sizes.rig <<'RIG'
obj Node
  id: U32
  none id == 0

obj Ref
  file: U32
  node: Node

enum Kind
  empty
  leaf

obj Tagged
  kind: Kind
  none kind == .empty

sub main()
  print($size(Node?) == $size(Node), $size(Ref?) == $size(Ref), $size(Tagged?) == $size(Tagged))
  print($size((Node?)?) > $size(Node), $size(Node) == 4)
RIG
out=$(RIG_STRICT_OPTIONALS= rig run sizes.rig 2>&1); expect_rc $? 0 "rig run sizes.rig"
expect_eq "$out" "true true true
true true" "the sizes"

cat >main.rig <<'RIG'
use std.os

obj Node
  id: U32
  none id == 0

called fun has(n: Node?) -> Bool
  n != none

called fun pick(i: Int) -> Node?
  return none if i > 4
  Node(id: U32(i + 1))

sub main()
  k = os.args().len
  print(has(pick(k)), has(pick(k + 9)))
RIG
rig build --release -o prog main.rig >out.txt 2>err.txt || fail "rig build --release: $(cat err.txt)"
expect_eq "$(./prog)" "true false" "the program"
body=$(objdump -d --no-show-raw-insn prog | awk '/[<]_*__rig_main\.has[>]:/ {f = 1; next} f && /^$/ {exit} f' | sed -E 's/^ *[0-9a-f]+:[[:space:]]*//')
[[ -n $body ]] || fail "no __rig_main.has in the program"
work=$(grep -vE '^(stp|ldp|ret|push|pop|nop|endbr64)\b|^mov[[:space:]]+(x29, sp|%rsp,%rbp|rbp, ?rsp)' <<<"$body")
grep -q '\[' <<<"$work" && fail "has reads memory: $body"
grep -q '(%' <<<"$work" && fail "has reads memory: $body"
n=$(grep -c . <<<"$work")
((n <= 2)) || fail "has is $n instructions besides its frame: $body"
exit 0
