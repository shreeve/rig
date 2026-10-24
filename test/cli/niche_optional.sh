# An object with a niche, bytes that no value of it holds, holds `none`
# there: its optional is the size of the object, and so is an optional of
# that while a value is left free. `has`, built optimized, reads the one
# word of the niche (a String's buffer address, 0 for `none`) and tests
# it, with no flag byte: at most two instructions besides its frame.
source "$ROOT/test/cli/_lib.sh"

cat >sizes.rig <<'RIG'
enum Color
  red
  green

obj Cheese
  name: String
  age: Int

obj Flagged
  n: Int
  on: Bool

obj Colored
  n: U32
  c: Color

obj Outer
  f: Flagged?
  n: Int

obj Boxed
  b: ^Flagged

obj Handle
  s: *Flagged

obj Wrap
  c: Cheese?
  n: Int

obj Node
  id: U32

type Three = [3]Flagged?

sub main()
  # A String's or a box's or a handle's address, a Bool, an enum's spare
  # tag, a field's own niche optional: none of them costs a byte.
  print($size(Cheese?) == $size(Cheese), $size(Flagged?) == $size(Flagged), $size(Colored?) == $size(Colored))
  print($size(Outer?) == $size(Outer), $size(Boxed?) == $size(Boxed), $size(Handle?) == $size(Handle))
  print($size((Flagged?)?) == $size(Flagged), $size(Three) == 3 * $size(Flagged))
  # An address has one value no address is, 0, so an optional of a
  # String-holding optional takes a flag; numbers alone have no niche.
  print($size((Cheese?)?) > $size(Cheese), $size(Wrap?) > $size(Wrap), $size(Node?) > $size(Node))
RIG
out=$(RIG_STRICT_OPTIONALS= rig run sizes.rig 2>&1); expect_rc $? 0 "rig run sizes.rig"
expect_eq "$out" "true true true
true true true
true true
true true true" "the sizes"

cat >main.rig <<'RIG'
use std.os

obj Cheese
  name: String
  age: Int

called fun has(c: ?Cheese?) -> Bool
  c != none

called fun pick(i: Int) -> Cheese?
  return none if i > 4
  Cheese(name: String("brie"), age: i)

sub main()
  k = os.args().len
  a = pick(k)
  b = pick(k + 9)
  print(has(?a), has(?b))
RIG
RIG_STRICT_OPTIONALS= "$RIG" emit main.rig >main.zig 2>err.txt || fail "rig emit: $(cat err.txt)"
expect_has "$(cat main.zig)" 'fn has(c: *const rig.Opt(Cheese)) bool' "has takes the niche optional"
expect_has "$(cat main.zig)" 'return rig.some(c.*) != null;' "has tests it through the helper"
RIG_STRICT_OPTIONALS= rig build --release -o prog main.rig >out.txt 2>err.txt || fail "rig build --release: $(cat err.txt)"
expect_eq "$(./prog)" "true false" "the program"
# The body ends at its last `ret`: on x86 the next function starts on a 16-byte
# boundary, and the gap is `nopl`, `nopw`, or `cs nopw` padding, not code of `has`.
body=$(objdump -d --no-show-raw-insn prog | awk '/[<]_*__rig_main\.has[>]:/ {f = 1; next} f && /^$/ {exit} f' | sed -E 's/^ *[0-9a-f]+:[[:space:]]*//' | awk '{l[NR] = $0} /^ret/ {r = NR} END {for (i = 1; i <= (r ? r : NR); i++) print l[i]}')
[[ -n $body ]] || fail "no __rig_main.has in the program"
work=$(grep -vE '^(stp|ldp|ret|push|pop|nop[a-z]*|endbr64)\b|^mov[[:space:]]+(x29, sp|%rsp,%rbp|rbp, ?rsp)' <<<"$body")
n=$(grep -c . <<<"$work")
((n <= 2)) || fail "has is $n instructions besides its frame: $body"
# One read, of the word at the optional's start: never a flag byte.
reads=$(grep -cE '\[|\(%' <<<"$work")
((reads == 1)) || fail "has reads memory $reads times: $body"
grep -qE 'ldrb|movzb|cmpb|byte ptr' <<<"$work" && fail "has reads a byte: $body"
grep -qE '\[x0\]|\[rdi\]|[ ,]\(%rdi\)' <<<"$work" || fail "has reads past the optional's first word: $body"
exit 0
