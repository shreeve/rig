# tools/migrate-std-0.3.py rewrites a program's uses of the std names
# 0.3.0 changed, so that it runs and prints what it printed; it leaves
# what it cannot rewrite as it is, with a MANUAL line, and a second run
# changes nothing. The program is Trig's code: its source-map and
# package.json readers (sourcemap/source_mapper.rig,
# packagejson/packagejson.rig), its round-half-even (jsnum/gostd.rig),
# and its insertion sort of names (module/resolver.rig), as they were
# written for 0.2.9's std, with the rest of Trig cut away.
source "$ROOT/test/cli/_lib.sh"

cat >trig.rig <<'EOF'
use std.bigint
use std.iter
use std.json
use std.math
use std.slices
use std.text as stdtext

error ParseError
  invalid

# sourcemap/source_mapper.rig
fun source_map_version(contents: ?String) -> Int?
  doc = json.new_doc()
  if not (!doc).parse(contents)
    return none
  return none if doc.kind(0) != .object
  version = 0
  j = 1
  while doc.kind(j) != .object_end
    key = ?doc.get_str(j)
    v = j + 1
    if key == "version" and doc.kind(v) == .int
      version = doc.get_int(v)
    j = doc.next(v)
  version

# packagejson/packagejson.rig
fun field_count(data: ?String) -> Int!ParseError
  doc = json.new_doc()
  return ParseError.invalid if not (!doc).parse(data)
  n = 0
  j = 1
  while doc.kind(j) != .object_end
    v = j + 1
    if doc.kind(v) == .bool
      n += 1 if doc.get_bool(v)
    else if doc.kind(v) == .float
      n += 1 if doc.get_float(v) > 0.5
    j = doc.next(v)
  n * 100 + doc.size()

# jsnum/gostd.rig: whether `q` rounds up, by the rest past it.
fun round_up(q: ?bigint.BigInt, rest: ?bigint.BigInt, half: ?bigint.BigInt, even: ?bigint.BigInt) -> Bool
  c = rest.compare(?half)
  c > 0 or c == 0 and not q.equals(?even)

# module/resolver.rig
sub sort_names(names: !List[String])
  for i in 1..names.len
    j = i
    while j > 0 and stdtext.compare(names[j - 1], names[j]) > 0
      !names.swap(j - 1, j)
      j -= 1

obj Upto
  n: Int
  hi: Int

  fun next(!@) -> Int?
    return none if @n >= @hi
    @n += 1
    @n

sub main()
  print(source_map_version("{\"version\": 3, \"file\": \"a.js\"}") ?? -1, source_map_version("{") ?? -1)
  print(field_count("{\"a\": true, \"b\": 0.75, \"c\": false}") catch -1, field_count("[") catch -1)
  q = bigint.from_int(4)
  five = bigint.from_int(5)
  print(round_up(?q, ?five, ?five, ?q), round_up(?q, ?five, ?five, ?five), q.to_f64())
  names: List[String] = List()
  for s in ["vue", "react", "angular"]
    !names.push(String(s))
  sort_names(!names)
  sought = String("vue")
  print(names, slices.contains(?names, +sought), math.powf(2.0, 10.0))
  u = Upto(n: 0, hi: 4)
  e = Upto(n: 0, hi: 0)
  print(iter.count(!u), iter.sum(!e) ?? 0, stdtext.compare("a", "b"))
EOF
cp trig.rig trig.orig
python3 "$ROOT/tools/migrate-std-0.3.py" trig.rig >out.txt 2>&1 || fail "migrate: $(cat out.txt)"
expect_has "$(cat out.txt)" "trig.rig: 18" "the sites rewritten"
expect_has "$(cat out.txt)" "MANUAL trig.rig:78: a \`compare\` result used as an \`Int\`" "a compare result printed"
expect_has "$(cat out.txt)" "18 rewritten, 1 MANUAL" "the totals"
grep -q 'stdtext.compare("a", "b")' trig.rig || fail "the MANUAL site changed: $(diff trig.orig trig.rig)"
for want in 'doc = json.parse(contents) catch |_|' 'doc = json.parse(data) catch return ParseError.invalid' \
    'key = ?doc.string(j)' 'doc.int(v)' 'n += 1 if doc.bool(v)' 'n += 1 if doc.float(v) > 0.5' 'n * 100 + doc.len' \
    'c = rest.order(?half)' 'c == .greater or c == .equal and q != even' \
    'names[j - 1].order(?names[j]) == .greater' 'q.to_float()' 'slices.contains(?names, ?sought)' \
    'math.pow(2.0, 10.0)' '(!u).count(), (!e).sum()'; do
    grep -qF -- "$want" trig.rig || fail "no [$want] in: $(diff trig.orig trig.rig)"
done
grep -q 'use std.iter' trig.rig && fail "use std.iter kept: $(cat trig.rig)"
cp trig.rig once.rig
python3 "$ROOT/tools/migrate-std-0.3.py" trig.rig >again.txt 2>&1 || fail "second run: $(cat again.txt)"
cmp -s trig.rig once.rig || fail "a second run changed: $(diff once.rig trig.rig)"

# The MANUAL site by hand, as its message says, and the program runs.
sed -i.bak 's/stdtext.compare("a", "b"))/"a".order("b"))/' trig.rig
got=$(rig run trig.rig 2>&1) || fail "trig.rig: $got"
expect_eq "$got" "3 -1
208 -1
false true 4.0
[\"angular\", \"react\", \"vue\"] true 1024.0
4 0 .less" "the migrated program's output"

# What would change meaning is not rewritten so: an integer literal in
# `powf` was a Float, and `pow` would take it as an Int, so it is
# written `2.0`; a `powf` of arguments not visibly Floats is MANUAL; and
# `?? 0 + 1` is `?? (0 + 1)`, so it is MANUAL, where `?? 0` before a `)`
# is rewritten.
cat >meaning.rig <<'END'
use std.iter
use std.math

obj Upto
  n: Int
  hi: Int

  fun next(!@) -> Int?
    return none if @n >= @hi
    @n += 1
    @n

fun third(x: Float, y: Float) -> Float
  math.powf(x, y) / 3.0

sub main()
  a = Upto(n: 0, hi: 4)
  b = Upto(n: 0, hi: 4)
  print(math.powf(2, -1), math.powf(2, 3) / 3, third(2.0, 3.0))
  print(iter.sum(!a) ?? 0 + 1, (iter.sum(!b) ?? 0))
END
python3 "$ROOT/tools/migrate-std-0.3.py" meaning.rig >m.txt 2>&1 || fail "migrate: $(cat m.txt)"
expect_has "$(cat m.txt)" "MANUAL meaning.rig:14: \`math.powf(x, y)\` of arguments not visibly Floats" "a powf of names"
expect_has "$(cat m.txt)" "MANUAL meaning.rig:20: \`iter.sum(!it) ?? ...\` with more after it" "a ?? 0 with more after it"
expect_has "$(cat m.txt)" "3 rewritten, 2 MANUAL" "the totals"
grep -qF 'print(math.pow(2.0, -1.0), math.pow(2.0, 3.0) / 3, third(2.0, 3.0))' meaning.rig || fail "powf literals: $(cat meaning.rig)"
grep -qF 'print(iter.sum(!a) ?? 0 + 1, ((!b).sum()))' meaning.rig || fail "iter.sum: $(cat meaning.rig)"
sed -i.bak -e 's/math.powf(x, y)/math.pow(x, y)/' -e 's/iter.sum(!a) ?? 0 + 1/(!a).sum() + 1/' -e '/use std.iter/d' meaning.rig
got=$(rig run meaning.rig 2>&1) || fail "meaning.rig: $got"
expect_eq "$got" "0.5 2.6666666666666665 2.6666666666666665
11 10" "the meaning kept"
