# Which functions `rig emit` writes `inline`: small ones that are only
# called, and no other (docs/INTERNALS.md, "Inlining"). Each is checked by
# the shape of its Zig; test/behavior/emit/inline_*.rig run the programs.
source "$ROOT/test/cli/_lib.sh"

# expect_lacks <text> <substring> <what>
expect_lacks() { ! grep -qF -- "$2" <<<"$1" || fail "$3: has [$2] in: $1"; }

emit() {
    local out
    out=$(rig emit "$1" 2>/dev/null) || fail "rig emit $1"
    printf '%s' "$out"
}

cat >small.rig <<'RIG'
fun next(n: Int) -> Int
  n + 1

sub main()
  print(next(41))
RIG
out=$(emit small.rig)
expect_has "$out" 'pub inline fn next(__rig_in_' "a small function that is called"
# A parameter is a run-time value inside, so a literal argument cannot
# fold the arithmetic into a compile error.
expect_has "$out" 'const n = rig.rt(__rig_in_' "a parameter bound through rig.rt"
expect_has "$out" 'pub fn main(' "main"
expect_lacks "$out" 'inline fn main' "main"

cat >kept.rig <<'RIG'
fun fact(n: Int) -> Int
  1 if n <= 1 else n * fact(n - 1)

fun even(n: Int) -> Bool
  true if n == 0 else odd(n - 1)

fun odd(n: Int) -> Bool
  false if n == 0 else even(n - 1)

fun plus_one(n: Int) -> Int
  n + 1

fun apply(f: ?fun(Int) -> Int, x: Int) -> Int
  f(x)

fun twice(n: Int) -> Int
  n * 2

sub main()
  print(fact(5))
  print(even(4))
  print(apply(plus_one, 1))
  print(twice(3))
RIG
out=$(emit kept.rig)
expect_has "$out" 'pub fn fact(' "direct recursion"
expect_has "$out" 'pub fn even(' "mutual recursion"
expect_has "$out" 'pub fn odd(' "mutual recursion"
expect_has "$out" 'pub fn plus_one(' "a function passed as a value"
expect_has "$out" 'pub inline fn apply(' "the function that takes it"
expect_has "$out" 'pub inline fn twice(' "a function beside them"

# A method is inlined as a function is.
cat >method.rig <<'RIG'
obj Counter
  n: Int

  fun get(?self) -> Int
    self.n

sub main()
  c = Counter(n: 2)
  print(c.get())
RIG
out=$(emit method.rig)
expect_has "$out" 'pub inline fn get(' "a method"

# A cycle of method calls, through a receiver, a type, or two types'
# methods, is found. A method call resolves by its receiver's type, as
# typecheck resolved it, so a method that calls another type's method of
# its name is a wrapper, inlined, and a method that calls itself is not.
cat >methods.rig <<'RIG'
obj Ping
  n: Int

  fun depth(?self, k: Int) -> Int
    0 if k == 0 else 1 + self.depth(k - 1)

  fun count(k: Int) -> Int
    0 if k == 0 else 1 + Ping.count(k - 1)

  fun hop(?self, p: ?Pong, k: Int) -> Int
    0 if k == 0 else p.hop(?self, k - 1)

  fun size(?self) -> Int
    self.n

obj Pong
  n: Int

  fun hop(?self, p: ?Ping, k: Int) -> Int
    0 if k == 0 else p.hop(?self, k - 1)

  fun size(?self, p: ?Ping) -> Int
    p.size() + self.n

sub main()
  a = Ping(n: 1)
  b = Pong(n: 2)
  print(a.depth(3), Ping.count(2), a.hop(?b, 4), b.size(?a))
RIG
out=$(emit methods.rig)
expect_has "$out" 'pub fn depth(' "recursion through the receiver"
expect_has "$out" 'pub fn count(' "recursion through the type"
expect_lacks "$out" 'inline fn hop(' "recursion through two types' methods"
expect_has "$out" 'pub inline fn size(__rig_in_self: *const Ping)' "a method of a name another calls"
expect_has "$out" 'pub inline fn size(__rig_in_self: *const Pong' "a method calling another type's method of its name"
out=$(rig run methods.rig 2>&1) || fail "rig run methods.rig: $out"
expect_eq "$out" "3 2 0 3" "methods.rig"

# A wrapper reached through fields, as a binder's `kind` calls its file's
# tree's, is inlined; one that reaches its own method through a field of
# its own type is on a cycle.
cat >wrappers.rig <<'RIG'
obj Ast
  kinds: List[Int]

  fun kind(?self, n: Int) -> Int
    self.kinds[n]

obj File
  ast: Ast

obj Binder
  file: File

  fun kind(?self, n: Int) -> Int
    self.file.ast.kind(n)

obj Node
  next: ^Node?
  n: Int

  fun kind(?self) -> Int
    if self.next as m
      return m.kind() + 1
    self.n

sub main()
  kinds: List[Int] = List()
  !kinds.push(7)
  b = Binder(file: File(ast: Ast(kinds: <kinds)))
  n = Node(next: ^Node(next: none, n: 3), n: 1)
  print(b.kind(0), n.kind())
RIG
out=$(emit wrappers.rig)
expect_has "$out" 'pub inline fn kind(__rig_in_self: *const Ast' "the method a wrapper calls"
expect_has "$out" 'pub inline fn kind(__rig_in_self: *const Binder' "a wrapper of another type's method of its name"
expect_has "$out" 'pub fn kind(self: *const Node' "a method that calls itself through a field"
out=$(rig run wrappers.rig 2>&1) || fail "rig run wrappers.rig: $out"
expect_eq "$out" "7 4" "wrappers.rig"

# A small member of a generic type is inlined as any function is: Zig
# writes one declaration for all its instances, so the decision is one,
# under the largest frame of its instances. One whose frame passes 64 KiB
# at an instance is called.
cat >members.rig <<'RIG'
obj Wrap[T]
  v: T

  fun get(?self) -> ?T
    ?self.v

  fun keeps(?self, i: Int) -> Int
    t = [9000 of self.v]
    i + t.len

sub main()
  a = Wrap[Int](v: 1)
  b = Wrap[Bool](v: true)
  print(a.get(), b.get(), a.keeps(1), b.keeps(2))
RIG
out=$(emit members.rig)
expect_has "$out" 'pub inline fn get(__rig_in_self: rig.ReadView(__rig_Self))' "a small member of a generic type"
expect_has "$out" 'pub fn keeps(self: rig.ReadView(__rig_Self)' "a member whose frame at one instance is 72 KB"
out=$(rig run members.rig 2>&1) || fail "rig run members.rig: $out"
expect_eq "$out" "1 true 9001 9002" "members.rig"
# Its parameters are bound through `rig.rt`, as any inlined function's:
# test/behavior/emit/inline_generic_member_overflow.rig runs it.
out=$(emit "$ROOT/test/behavior/emit/inline_generic_member_overflow.rig")
expect_has "$out" 'pub inline fn bump(__rig_in_self: rig.ReadView(__rig_Self), __rig_in_n: i64) i64 {' "a member of a generic type with a literal argument"
expect_has "$out" 'const n = rig.rt(__rig_in_n);' "a member's parameter bound through rig.rt"

# std.hash's `ensure` and `ensure_with` are inlined into the code that
# calls them, so a lookup that finds its key costs no call, as `edit`'s
# does (bench/hash).
cat >ensure.rig <<'RIG'
use std.hash

fun zero(k: ?Int) -> Int
  0

sub main()
  m = hash.Map[Int, Int].new()
  a = (!m).ensure(1, 5)
  a += 1
  b = (!m).ensure_with(2, zero)
  b += 2
  if (!m).edit(1) as c
    c += 3
  print(m.get(1), m.get(2))
RIG
emit ensure.rig >/dev/null
lib=$(cat "$RIG_OUT_DIR"/programs/ensure/__rig_std_h?sh.zig) || fail "std's module is not in the package"
expect_has "$lib" 'pub inline fn ensure(' "Map.ensure"
expect_has "$lib" 'pub inline fn ensure_with(' "Map.ensure_with"
expect_has "$lib" 'pub inline fn edit(' "Map.edit"
out=$(rig run ensure.rig 2>&1) || fail "rig run ensure.rig: $out"
expect_eq "$out" "9 2" "ensure.rig"

# A Map's or Set's write method that is inlined into its caller holds no
# loop, through any inline function it calls: the path that adds a new
# key is a call (`add_entry`, `add_new`), so a hot loop of hits keeps its
# layout. `ensure`'s `while (true)`, which stands where an unwrap that
# traps would (std/hash.rig), returns on its first pass.
cat >writes.rig <<'RIG'
use std.hash

fun one(k: ?Int) -> Int
  1

sub main()
  m = hash.Map[Int, Int].new()
  !m.put(1, 2)
  old = (!m).replace(1, 3)
  added = (!m).put_new(2, 4)
  a = (!m).ensure(3, 5)
  a += 1
  b = (!m).ensure_with(4, one)
  b += 1
  if (!m).edit(1) as c
    c += 1
  gone = (!m).take(2)
  s = hash.Set[Int].new()
  fresh = (!s).add(7)
  out = (!s).take(7)
  print(old, added, gone, fresh, out, m.len, s.len)
RIG
emit writes.rig >/dev/null
out=$(rig run writes.rig 2>&1) || fail "rig run writes.rig: $out"
expect_eq "$out" "2 true 4 true 7 3 0" "writes.rig"
python3 - "$RIG_OUT_DIR"/programs/writes/__rig_std_h?sh.zig <<'PY' || fail "an inlined write method holds a loop"
import re, sys
src = open(sys.argv[1]).read().splitlines()
fns, struct, i = {}, None, 0
while i < len(src):
    m = re.match(r'^(?:pub )?(?:fn (\w+)\(.*\) type \{|const (\w+) = struct \{)', src[i])
    if m:
        struct = m.group(1) or m.group(2)
        i += 1
        continue
    m = re.match(r'^(\s*)pub (inline |noinline )?fn (\w+)\(', src[i])
    if m:
        body, i = [], i + 1
        while i < len(src) and src[i] != m.group(1) + '}':
            body.append(src[i])
            i += 1
        fns[(struct, m.group(3))] = (m.group(2) == 'inline ', body)
    i += 1

def loops(struct, name, seen):
    if (struct, name) in seen or (struct, name) not in fns:
        return []
    seen.add((struct, name))
    inline, body = fns[(struct, name)]
    if not inline:
        return []
    found = [f'{struct}.{name}: {l.strip()}' for l in body if re.search(r'\b(while|for) \(', l) and 'while (true)' not in l]
    for line in body:
        for c in re.finditer(r'\bself(?:\.table)?\.(\w+)\(', line):
            for s in (struct, 'Table'):
                found += loops(s, c.group(1), seen)
    return found

bad = []
for struct, names in {'Map': ['put', 'replace', 'put_new', 'ensure', 'ensure_with', 'edit', 'take'], 'Set': ['add', 'take']}.items():
    for n in names:
        if (struct, n) not in fns:
            bad.append(f'no {struct}.{n}')
            continue
        if not fns[(struct, n)][0]:
            bad.append(f'{struct}.{n} is not inlined')
        bad += loops(struct, n, set())
if bad:
    print('\n'.join(bad))
    sys.exit(1)
PY

# A body of more than inlining.max_size nodes (60) is called.
{
    echo 'fun long(n: Int) -> Int'
    echo '  total = n'
    for i in $(seq 1 30); do echo "  total += $i * n"; done
    echo '  total'
    echo
    echo 'sub main()'
    echo '  print(long(2))'
} >long.rig
out=$(emit long.rig)
expect_has "$out" 'pub fn long(' "a long body"

# A function holds at most 13 MiB of values on its stack, and Zig puts the
# frame of an inlined call in its caller's: a function that keeps much,
# and calls that add much to a frame, are not inlined.
cat >frames.rig <<'RIG'
fun keeps() -> Int
  a = [10000 of 1]
  a[3]

fun small() -> Int
  a = [2048 of 1]
  a[3]

sub main()
  print(keeps())
  print(small() + small() + small())
RIG
out=$(emit frames.rig)
expect_has "$out" 'pub fn keeps(' "a function with a large frame"
expect_has "$out" 'pub inline fn small(' "calls that add 48 KiB to a frame"
{
    echo 'fun small() -> Int'
    echo '  a = [2048 of 1]'
    echo '  a[3]'
    echo
    echo 'sub main()'
    echo -n '  print(small()'
    for i in 1 2 3 4 5; do echo -n ' + small()'; done
    echo ')'
} >frames5.rig
out=$(emit frames5.rig)
expect_has "$out" 'pub fn small(' "calls that would add 96 KiB to a frame"

# A chain of functions that each call the next twice would have Zig analyze
# the innermost 2^n times: a function that expands to more than
# inlining.max_expanded (320) nodes is called.
{
    echo 'fun f0(n: Int) -> Int'
    echo '  n + 1'
    for i in $(seq 1 12); do
        echo
        echo "fun f$i(n: Int) -> Int"
        echo "  f$((i - 1))(n) + f$((i - 1))(n + 1)"
    done
    echo
    echo 'sub main()'
    echo '  print(f12(1))'
} >chain.rig
out=$(emit chain.rig)
expect_has "$out" 'pub inline fn f0(' "the innermost of a chain"
expect_has "$out" 'pub fn f' "a function that would expand too far is called"

# A small entry that calls a large function inlines, and the large one is
# not inlined back into it: the size rule measures each body as written,
# so the large function stays one out-of-line copy for every call site.
{
    echo 'fun run(n: Int) -> Int'
    echo '  total = n'
    for i in $(seq 1 30); do echo "  total += $i * n"; done
    echo '  total'
    echo
    echo 'fun entry(n: Int) -> Int'
    echo '  n if n < 2 else run(n)'
    echo
    echo 'sub main()'
    echo '  print(entry(1) + entry(5) + entry(9))'
} >entry.rig
out=$(emit entry.rig)
expect_has "$out" 'pub inline fn entry(' "the small entry"
expect_has "$out" 'pub fn run(' "the large function it calls"
expect_lacks "$out" 'inline fn run(' "the large function it calls"

# The `next` a `for` over an iterator calls is a call: a `next` that loops
# over another of its own kind is on a cycle and called.
cat >iter.rig <<'RIG'
obj Count
  lo: Int
  hi: Int

  fun next(!self) -> Int?
    return none if self.lo >= self.hi
    self.lo += 1
    if self.hi > 100
      inner = Count(lo: 0, hi: 1)
      for x in !inner
        print("inner", x)
    self.lo - 1

sub main()
  c = Count(lo: 0, hi: 3)
  for n in !c
    print(n)
RIG
out=$(emit iter.rig)
expect_has "$out" 'pub fn next(' "an iterator that loops over itself"
expect_lacks "$out" 'inline fn next' "an iterator that loops over itself"

# A call that may reach an inlined function is read through rig.rt, so the
# result is a run-time value.
out=$(emit small.rig)
expect_has "$out" 'rig.print(.{ rig.rt(next(41)), "\n" })' "a call of an inlined function"

# A function that keeps nearly all of `sema.max_frame_bytes` calls what
# would take it over, though the callee is small enough to inline.
cat >framefull.rig <<'RIG'
fun bump(i: Int) -> Int
  t = [4000 of i]
  t[i % 4000] + 1

fun near(i: Int) -> Int
  a = [850000 of 1]
  b = [850000 of 2]
  bump(i) + a[i] + b[i]

sub main()
  print(near(3))
RIG
out=$(emit framefull.rig)
expect_has "$out" 'pub fn bump(' "a callee that would overfill the caller's frame"
# Its frame is large, so it is never inlined either (`sema.noinline_reach`).
expect_has "$out" 'pub noinline fn near(' "the caller"

# An instance of a function with compile-time values (Bool, Int, enum) is
# sized and inlined as any function, and so are the helpers it calls; one
# with a compile-time type parameter is called.
cat >ctvalue.rig <<'RIG'
enum Mode
  strict
  loose

fun step(s: ?String, i: Int) -> Int
  i + 1 if i < s.len else i

fun pick(s: ?String, i: Int) -> Int
  step(s, i) + 1

fun walk[dense: Bool](s: ?String) -> Int
  i = 0
  while i < s.len
    i = pick(s, i)
    i = step(s, i) if dense else i
  i

fun times[n: Int](x: Int) -> Int
  x * n

fun mode[m: Mode](x: Int) -> Int
  x + 1 if m == .strict else x - 1

fun same[T](x: T) -> T
  x

fun down[b: Bool](x: Int) -> Int
  x if x <= 0 else down[not b](x - 1)

sub main()
  print(walk[true]("abc"), walk[false]("abc"))
  print(times[3](2), mode[.strict](1), mode[.loose](1), same(5), down[true](4))
RIG
out=$(emit ctvalue.rig)
expect_has "$out" 'pub inline fn walk(comptime dense: bool' "a function with a compile-time Bool"
expect_has "$out" 'pub inline fn times(comptime n: i64' "a function with a compile-time Int"
expect_has "$out" 'pub inline fn mode(comptime m: ' "a function with a compile-time enum"
expect_has "$out" 'pub inline fn step(' "the callee of an instance"
expect_has "$out" 'pub inline fn pick(' "the callee of an instance"
expect_has "$out" 'pub fn same(comptime T: type' "a function with a compile-time type"
expect_has "$out" 'pub fn down(' "recursion through an instance"

# A function that is called from one place only, in a function with
# compile-time values, is exempt from inlining.max_expanded (each instance
# of the caller holds a copy): `once` here expands to over 320 nodes. The
# same body called from an ordinary function, or from two places, is called.
{
    echo 'fun leaf(n: Int) -> Int'
    echo '  total = n'
    for i in $(seq 1 18); do echo "  total += $i * n"; done
    echo '  total'
    for name in once twice plain; do
        echo
        echo "fun $name(n: Int) -> Int"
        echo '  leaf(n) + leaf(n + 1) + leaf(n + 2) + leaf(n + 3) + leaf(n + 4) + leaf(n + 5) + leaf(n + 6) + leaf(n + 7)'
    done
    echo
    echo 'fun inst[b: Bool](n: Int) -> Int'
    echo '  once(n) if b else twice(n) + twice(n + 1)'
    echo
    echo 'sub main()'
    echo '  print(inst[true](1) + inst[false](2) + plain(3))'
} >once.rig
out=$(emit once.rig)
expect_has "$out" 'pub inline fn leaf(' "the leaf"
expect_has "$out" 'pub inline fn once(' "an expansion over the limit, called from one instance function"
expect_has "$out" 'pub fn twice(' "the same expansion, called from two places"
expect_has "$out" 'pub fn plain(' "the same expansion, called from an ordinary function"

# Inlining keeps what the proofs omitted: a Simd read proven in bounds
# stays proven in a function that is inlined, whether it is small or is
# called from one place only.
{
    echo 'fun scan(s: ?String, at: Int) -> Int'
    echo '  i = at'
    echo '  while i + 16 <= s.len : i += 16'
    echo '    v = s.read[Simd[U8, 16]](i)'
    echo '    if (v == 0x22).first() as k'
    echo '      return i + k'
    echo '  s.len'
    echo
    echo 'sub main()'
    echo '  print(scan("abc\"abcdefghijklmnopq", 0))'
} >proven.rig
out=$(emit proven.rig)
expect_has "$out" 'pub inline fn scan(' "a function with a proven read"
expect_has "$out" 'rig.simdReadProven(' "the read stays proven when inlined"
