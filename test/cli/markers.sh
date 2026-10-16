# timeout: 900
# The function markers (SPEC.md, "Function markers"): `inline fun` is
# emitted `inline fn` at any size, `called fun` is emitted `noinline fn`,
# and `rarely fun` starts with Zig's cold hint; the last two are never
# inlined by the compiler's own rule. Each is checked by the shape of its
# Zig; then std.json's shape, one parser with two compile-time instances,
# is built in --release, where the `inline` helper leaves no function of
# its own, the rarely called one keeps one, and a `called` parser keeps
# one function for each instance.
source "$ROOT/test/cli/_lib.sh"

expect_lacks() { ! grep -qF -- "$2" <<<"$1" || fail "$3: has [$2] in: $1"; }

emit() {
    local out
    out=$(rig emit "$1" 2>&1) || fail "rig emit $1: $out"
    printf '%s' "$out"
}

# The first lines of the body of the Zig function `name`.
body() { grep -A"$3" -E "fn $2\(" <<<"$1" | tail -n +2; }

cat >shapes.rig <<'RIG'
inline fun big(a: Int) -> Int
  x = a
  x = x * 3 + 1
  x = x * 3 + 1
  x = x * 3 + 1
  x = x * 3 + 1
  x = x * 3 + 1
  x = x * 3 + 1
  x = x * 3 + 1
  x = x * 3 + 1
  x = x * 3 + 1
  x = x * 3 + 1
  x = x * 3 + 1
  x = x * 3 + 1
  x = x * 3 + 1
  x = x * 3 + 1
  x = x * 3 + 1
  x = x * 3 + 1
  x = x * 3 + 1
  x = x * 3 + 1
  x = x * 3 + 1
  x = x * 3 + 1
  x

rarely fun small(a: Int) -> Int
  a + 1

called fun tiny(a: Int) -> Int
  a - 1

obj Wrap[T]
  value: T

  inline fun get(?self) -> T
    self.value

  rarely fun peek(?self) -> T
    self.value

  called fun same(?self) -> T
    self.value

inline fun larger[T](a: T, b: T) -> T
  a if a > b else b

sub main()
  w = Wrap[Int](value: 2)
  print(big(1), small(2), tiny(3), w.get(), w.peek(), w.same(), larger(3, 4))
RIG
out=$(emit shapes.rig)
expect_has "$out" 'pub inline fn big(__rig_in_a: i64) i64 {' "inline fun over the size limit"
expect_has "$out" 'pub inline fn get(' "inline method of a generic type"
expect_has "$out" 'pub inline fn larger(comptime T: type, ' "inline fun with a type parameter"
expect_has "$out" 'pub fn small(a: i64) i64 {' "rarely fun: not inlined"
expect_has "$out" 'pub noinline fn tiny(a: i64) i64 {' "called fun: noinline"
expect_has "$out" 'pub noinline fn same(' "called method of a generic type: noinline"
expect_eq "$(body "$out" tiny 1)" '    @setEvalBranchQuota(rig.eval_quota);' "called fun: no cold hint"
expect_eq "$(body "$out" small 2)" $'    @branchHint(.cold);\n    @setEvalBranchQuota(rig.eval_quota);' "rarely fun: the cold hint first"
expect_eq "$(body "$out" peek 1 | sed 's/^ *//')" '@branchHint(.cold);' "rarely method of a generic type: the cold hint first"
# Without the markers, the compiler's rule decides: `big` is over its size
# and is called; `small`, `get`, and `peek` are inlined; `larger`, generic
# over a type, is not.
sed -E 's/^( *)(inline|called|rarely) /\1/' shapes.rig >plain.rig
out=$(emit plain.rig)
expect_has "$out" 'pub fn big(a: i64) i64 {' "big without a marker"
expect_has "$out" 'pub inline fn small(' "small without a marker"
expect_has "$out" 'pub fn larger(comptime T: type, ' "larger without a marker"
expect_lacks "$out" '@branchHint' "no marker, no hint"
expect_lacks "$out" 'noinline' "no marker, no noinline"
# A marker changes no meaning: the program prints the same without them.
for f in shapes plain; do
    out=$(rig run $f.rig 2>&1) || fail "run $f: $out"
    expect_eq "$out" "5230176601 3 2 2 2 2 4" "$f run"
done

# std.json's shape: `doc[dense]` has two instances, each calling `number`,
# which is over the size limit, and rarely `utf8_text`.
cat >doc.rig <<'RIG'
# The shape std.json wants: one parser, two compile-time instances that
# each call one helper over the size the compiler inlines by itself.

DOT: U8 = 0x2E
ZERO: U8 = 0x30
NINE: U8 = 0x39
LOWER_E: U8 = 0x65

fun is_digit(b: U8) -> Bool
  b >= ZERO and b <= NINE

# A number at `i`: its integer part times 100, plus the bytes it spans.
fun number(s: ?String, i: Int) -> Int
  n = 0
  j = i
  while j < s.len and is_digit(s[j])
    n = n * 10 + Int(s[j] - ZERO)
    j += 1
  if j < s.len and s[j] == DOT
    j += 1
    while j < s.len and is_digit(s[j])
      j += 1
  if j < s.len and s[j] == LOWER_E
    j += 1
    e = 0
    while j < s.len and is_digit(s[j])
      e = e * 10 + Int(s[j] - ZERO)
      j += 1
    while e > 0
      n *= 10
      e -= 1
  n * 100 + (j - i)

# A byte past ASCII, which a document rarely holds.
fun utf8_text(s: ?String, i: Int) -> Int
  Int(s[i])

# The parser: `dense` documents keep only the numbers' values.
fun doc[dense: Bool](s: ?String) -> Int
  total = 0
  words = 0
  spaces = 0
  i = 0
  while i < s.len
    b = s[i]
    if b >= 128
      total += utf8_text(s, i)
      i += 1
    else if is_digit(b)
      v = number(s, i)
      total += v / 100 if dense else v
      i += v % 100
    else if b == 0x20 or b == 0x0A or b == 0x09 or b == 0x0D
      spaces += 1
      i += 1
    else if b == 0x2C or b == 0x3A
      words += 2
      i += 1
    else
      words += 1
      i += 1
  if dense
    return total
  j = 0
  lines = 0
  while j < s.len
    if s[j] == 0x0A
      lines += 1
    j += 1
  total + words * 1000000 + spaces * 10000000 + lines * 100000000

sub main()
  s = "12 3 4.5 2e2 é"
  print(doc[true](s), doc[false](s))
RIG
sed -e 's/^fun number/inline fun number/' -e 's/^fun utf8_text/rarely fun utf8_text/' doc.rig >marked.rig
sed -e 's/^fun doc/called fun doc/' marked.rig >called.rig
out=$(emit doc.rig)
expect_has "$out" 'pub fn number(s: []const u8, i: i64) i64 {' "doc: number is called"
expect_has "$out" 'pub inline fn utf8_text(' "doc: utf8_text is inlined"
expect_has "$out" 'pub fn doc(comptime dense: bool, ' "doc: one Zig function, two instances"
out=$(emit marked.rig)
expect_has "$out" 'pub inline fn number(__rig_in_s: []const u8, __rig_in_i: i64) i64 {' "marked: number inlined into each instance"
expect_has "$out" 'pub fn utf8_text(s: []const u8, i: i64) i64 {' "marked: utf8_text is called"
expect_eq "$(body "$out" utf8_text 1)" '    @branchHint(.cold);' "marked: utf8_text is cold"
out=$(emit called.rig)
expect_has "$out" 'pub noinline fn doc(comptime dense: bool, s: []const u8) i64 {' "called: doc is noinline, each instance"
expect_has "$out" 'pub inline fn number(' "called: number still inlined"
for f in doc marked called; do
    out=$(rig run $f.rig 2>&1) || fail "run $f: $out"
    expect_eq "$out" "583 40022273" "run $f"
    rig build --release -o prog_$f $f.rig >build.log 2>&1 || fail "release $f: $(cat build.log)"
    out=$(./prog_$f 2>&1) || fail "release $f ran: $out"
    expect_eq "$out" "583 40022273" "release $f"
done
# In the optimized program the marked `number` has no function of its
# own, inlined into both instances, and the rarely called `utf8_text`
# keeps one, which LLVM leaves alone. A `called` `doc` keeps one function
# for each of its two instances, which LLVM may otherwise inline into
# `main`.
if command -v nm >/dev/null; then
    syms() { nm "$1" | grep -oE '__rig_main\.(number|utf8_text)$' | sort -u | tr '\n' ' '; }
    docs() { nm "$1" | grep -cE '__rig_main\.doc'; }
    expect_eq "$(syms prog_doc)" "__rig_main.number " "release doc: functions kept"
    expect_eq "$(syms prog_marked)" "__rig_main.utf8_text " "release marked: functions kept"
    expect_eq "$(syms prog_called)" "__rig_main.utf8_text " "release called: functions kept"
    expect_eq "$(docs prog_called)" 2 "release called: one function for each of doc's instances"
fi

# A marked `inline` function whose frame alone would make it `noinline`
# (4 times its reach passes 1 MiB) is still written `inline fn`: its
# values land in its caller, whose account holds them (its marked part),
# and the caller is the frame written `noinline`.
cat >large.rig <<'RIG'
inline fun huge(i: Int) -> Int
  t = [40000 of i]
  t[i % 40000]

fun near(i: Int) -> Int
  huge(i) + 1

sub main()
  print(near(3))
RIG
out=$(emit large.rig)
expect_has "$out" 'pub inline fn huge(' "a large marked function"
expect_lacks "$out" 'noinline fn huge(' "a large marked function"
expect_has "$out" 'pub noinline fn near(' "its caller, whose frame holds it"
facts=$(rig check --facts=frames large.rig 2>&1) || fail "facts large.rig: $facts"
marked=$(awk '$2 == "`near`" { print $(NF - 1) }' <<<"$facts")
[[ -n $marked && $marked -ge 320000 ]] || fail "near's account lacks huge's 320000 bytes: $facts"
out=$(rig run large.rig 2>&1) || fail "run large.rig: $out"
expect_eq "$out" 4 "large.rig"

# Calls of marked `inline` functions nest at most 256 deep
# (`typecheck.max_inline_depth`): Zig analyzes each inlined body inside
# the one around it, and runs out of its own stack some thousands deep.
# chain <n>: `main` calls g0, and each marked g_i calls g_(i+1), n deep.
chain() {
    local i
    for i in $(seq 0 $(($1 - 1))); do
        echo "inline fun g$i(x: Int) -> Int"
        echo "  g$((i + 1))(x) + 1"
        echo
    done
    echo "fun g$1(x: Int) -> Int"
    echo "  x"
    echo
    echo 'sub main()'
    echo '  print(g0(0))'
}
chain 256 >deep256.rig
out=$(rig run deep256.rig 2>&1) || fail "a chain of 256 marked calls: $out"
expect_eq "$out" 256 "a chain of 256 marked calls"
chain 257 >deep257.rig
out=$(rig check deep257.rig 2>&1) && fail "a chain of 257 marked calls is accepted"
expect_has "$out" 'calls of `inline` functions nest more than 256 deep through this one' "a chain of 257 marked calls"
chain 10000 >deep10000.rig
out=$(rig check deep10000.rig 2>&1) && fail "a chain of 10,000 marked calls is accepted"
expect_has "$out" 'nest more than 256 deep' "a chain of 10,000 marked calls"

# `rig test` runs a program's test blocks with its marked functions.
cat >tested.rig <<'RIG'
inline fun twice(n: Int) -> Int
  n * 2

rarely fun fallback(n: Int) -> Int
  0 - n

called fun kept(n: Int) -> Int
  n + 100

sub main()
  print(twice(1))

test "markers"
  print(twice(3), fallback(4), kept(5))
RIG
out=$(rig test tested.rig 2>&1) || fail "rig test: $out"
expect_has "$out" "6 -4 105" "rig test"
true
