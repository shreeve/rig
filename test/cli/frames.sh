# timeout: 900
# Each frame owner's account (`rig check --facts=frames`: its own reach,
# what the calls of functions marked `inline` add, and what the functions
# the rule inlines into it add) against the stack Zig's code reserves for
# it, for every kind of owner (a function, each instance of a generic one,
# a closure, a test block, a `drop` body, `main`) and every body that
# belongs to the owner around it (a `defer` body at each exit, a match
# arm), each with the calls of a 16 KB helper the rule inlines; and for
# owners that call marked functions in every way a call can (a chain,
# generic instances, a compile-time value, a method directly and through
# a box, an iterator, a parameter by value), and owners the rule must
# not inline a function into because the marked functions it holds would
# land, uncounted, in them (a wrapper of a generic one, and a helper
# called through a marked one many times), and one the rule inlines a
# function with a parameter by value into. An account lower than the
# real frame by more than
# 4 KiB fails. The real frame is the prologue's reservation, read from
# the assembly Zig writes for aarch64, so the test runs on an aarch64 Mac
# only. Debug checks every owner; --release checks only owners whose
# callees are all marked, since LLVM inlines a function the rule leaves
# out of line of its own accord, which no count of Rig's models.
source "$ROOT/test/cli/_lib.sh"

if [[ $(uname -s) != Darwin || $(uname -m) != arm64 ]]; then
    echo "skipped: reads aarch64 assembly"
    exit 0
fi

# check.py <accounts> <asm> [asm...] -- <least> <label>=<pattern>...:
# each owner `label`'s account against the stack the functions matching
# `pattern` reserve; an owner whose account is under `least` holds
# nothing inlined, so it measures nothing.
cat >check.py <<'PY'
import re, sys

args = sys.argv[1:]
sep = args.index('--')
accounts_path, asms = args[0], args[1:sep]
least = int(args[sep + 1])
owners = dict(a.split('=', 1) for a in args[sep + 2:])

def frames(path):
    """The stack each function's prologue reserves: each `sub sp, sp, #N`
    (`, lsl #12` scales it by 4096) and the pair `stp ..., [sp, #-N]!`."""
    out, fn = {}, None
    for line in open(path, errors='replace'):
        m = re.match(r'^_+rig_main\.(.+):$', line.rstrip('\n'))
        if m:
            fn = m.group(1)
            out[fn] = 0
            continue
        t = line.split()
        if fn is None or not t:
            continue
        if t[0] == '.cfi_endproc':
            fn = None
        elif t[0] == 'sub' and t[1:3] == ['sp,', 'sp,']:
            n = int(t[3].strip('#,'), 0)
            out[fn] += n * 4096 if len(t) > 5 and t[5] == '#12' else n
        elif t[0] == 'stp' and len(t) > 4 and t[3] == '[sp,' and re.match(r'^#-\d+\]!$', t[4]):
            out[fn] += int(t[4][2:-2])
    return out

real = {}
for path in asms:
    real.update(frames(path))
accounts = {}
for line in open(accounts_path):
    # "L:C label bytes reach marked auto"; a label has spaces. What the
    # marked calls and the rule inline into a frame land in it.
    head, _, reach, marked, auto = line.rsplit(None, 4)
    accounts[head.split(None, 1)[1]] = int(reach) + int(marked) + int(auto)
bad = []
for label, pattern in owners.items():
    if label not in accounts:
        bad.append(f'{label}: no account')
        continue
    if accounts[label] < least:
        bad.append(f'{label}: nothing is inlined into it (account {accounts[label]})')
    found = [n for n in real if re.fullmatch(pattern, n)]
    if not found:
        bad.append(f'{label}: no function `{pattern}` in the assembly')
    for n in found:
        if real[n] > accounts[label] + 4096:
            bad.append(f'{label}: Zig reserves {real[n]} bytes for `{n}`; its account is {accounts[label]}')
if bad:
    print('FAIL: ' + '\n'.join(bad))
    sys.exit(1)
PY

cat >ev.rig <<'RIG'
fun v(i: Int) -> Int
  t = [2000 of 0]
  for k in 0..2000
    t[k] = k + i
  t[i % 2000]

fun gen[T](x: T, i: Int) -> Int
  y = x
  v(i) + v(i + 1) + v(i + 2)

obj Res
  n: Int

  drop(!self)
    print(v(self.n) + v(self.n + 1) + v(self.n + 2))

called fun plain(i: Int) -> Int
  v(i) + v(i + 1) + v(i + 2)

called fun closure(i: Int) -> Int
  f = |+i|
    v(i) + v(i + 1) + v(i + 2)
  f()

called fun later(i: Int) -> Int
  defer print(v(i))
  return 1 if i == 5
  return 2 if i == 6
  i

called fun arm(i: Int) -> Int
  match i
    0 => v(i) + v(i + 1) + v(i + 2)
    _ => 1

test "pile"
  print(v(0) + v(1) + v(2))

sub main()
  r = Res(n: 0)
  print(plain(0), closure(0), later(0), arm(0), gen(1, 0), gen(true, 0))
  print(v(0) + v(1) + v(2))
RIG
out=$(rig run ev.rig 2>&1) || fail "run: $out"
expect_eq "$out" $'0\n6 6 0 6 6 6\n6\n6' "run"
out=$(rig test ev.rig 2>&1) || fail "test: $out"
expect_has "$out" "1 passed, 0 failed" "test"
rig check --tests --facts=frames ev.rig >accounts.txt 2>&1 || fail "facts: $(cat accounts.txt)"
rig emit ev.rig >/dev/null 2>&1 || fail "emit"
pkg=$RIG_OUT_DIR/programs/ev
# The emitted module holds its tests' functions, which only the table of
# tests names: a root that names the table has Zig compile them too.
echo 'comptime { _ = &@import("__rig_main.zig").__rig_tests; }' >"$pkg/__rig_frames_tests.zig"
(cd "$pkg" && "${ZIG:-zig}" build-obj -O Debug -femit-asm="$PWD/../ev-main.s" -fno-emit-bin __rig_main.zig) >build.log 2>&1 || fail "asm: $(cat build.log)"
(cd "$pkg" && "${ZIG:-zig}" build-obj -O Debug -femit-asm="$PWD/../ev-test.s" -fno-emit-bin __rig_frames_tests.zig) >build.log 2>&1 || fail "test asm: $(cat build.log)"
python3 check.py accounts.txt "$pkg/../ev-main.s" "$pkg/../ev-test.s" -- 16000 \
    '`gen`=gen__func_\d+' \
    '`drop`=Res\.__rig_user_drop' \
    '`plain`=plain' \
    'a closure=closure__struct_\d+\.__rig_invoke' \
    '`later`=later' \
    '`arm`=arm' \
    'test "pile"=__rig_test_0' \
    '`main`=__rig_run_main' || exit 1

# Owners that call marked `inline` functions.
cat >iv.rig <<'RIG'
inline fun big(i: Int) -> Int
  t = [100000 of 0]
  for k in 0..100000
    t[k] = k * i
  t[(i * 7 + 1) % 100000]

inline fun mid(i: Int) -> Int
  big(i) + big(i + 1)

inline fun gen[T](x: T, i: Int) -> Int
  t = [50000 of 0]
  for k in 0..50000
    t[k] = k + i
  u = [x, x, x, x]
  t[(i * 3 + 2) % 50000] + 4

inline fun bign[n: Int](i: Int) -> Int
  t = [80000 of n]
  for k in 0..80000
    t[k] += k * i
  t[(i * 5) % 80000]

obj G[T]
  v: T

  inline fun deep(?self, i: Int) -> Int
    t = [60000 of 0]
    for k in 0..60000
      t[k] = k - i
    t[(i * 11) % 60000]

obj Count
  n: Int

  inline fun next(!self) -> Int?
    t = [40000 of 0]
    for k in 0..40000
      t[k] = k + self.n
    self.n += 1
    return none if self.n > 2
    t[(self.n * 13) % 40000]

# Unmarked: the rule must not inline them, since the marked functions
# they hold land in their callers.
fun wrap(i: Int) -> Int
  gen(1, i)

fun small(i: Int) -> Int
  t = [7000 of 0]
  for k in 0..7000
    t[k] = k + i
  t[(i * 3) % 7000]

inline fun holds(i: Int) -> Int
  small(i) + 1

called sub wrapped(i: Int)
  print(wrap(i) + wrap(i + 1) + wrap(i + 2) + wrap(i + 3))

called sub piled(i: Int)
  print(holds(i) + holds(i + 1) + holds(i + 2) + holds(i + 3) + holds(i + 4) + holds(i + 5) + holds(i + 6) + holds(i + 7) + holds(i + 8) + holds(i + 9) + holds(i + 10) + holds(i + 11))

called sub chain(i: Int)
  print(mid(i) + big(i))

called sub generic(i: Int)
  print(gen(1, i) + gen(true, i))

called sub values(i: Int)
  print(bign[1](i) + bign[2](i))

called sub method(i: Int)
  g = G[Int](v: 1)
  b = ^G[Int](v: 2)
  print(g.deep(i) + b.deep(i))

called sub loop()
  c = Count(n: 0)
  for x in !c
    print(x)

# Parameters by value: an inlined function's code copies each into a
# local of its own (`rig.rt`), beside the argument and the parameter.
obj Big
  a: [20000]Int

obj Mid
  a: [2600]Int

inline fun take(b: Big, i: Int) -> Int
  b.a[i % 20000]

fun pick(m: Mid, i: Int) -> Int
  m.a[i % 2600]

called fun byvalue(b: ?Big, i: Int) -> Int
  take(b, i) + take(b, i + 1)

called fun byrule(m: ?Mid, i: Int) -> Int
  pick(m, i)

sub main()
  chain(1)
  generic(1)
  values(1)
  method(1)
  loop()
  wrapped(1)
  piled(1)
  hb = ^Big(a: [20000 of 1])
  hm = ^Mid(a: [2600 of 3])
  print(byvalue(hb, 1), byrule(hm, 1))
RIG
out=$(rig run iv.rig 2>&1) || fail "run iv: $out"
expect_eq "$out" $'46\n20\n13\n20\n13\n27\n64\n324\n2 3' "run iv"
rig check --facts=frames iv.rig >iv-accounts.txt 2>&1 || fail "facts iv: $(cat iv-accounts.txt)"
rig emit iv.rig >/dev/null 2>&1 || fail "emit iv"
pkg=$RIG_OUT_DIR/programs/iv
for mode in Debug ReleaseSafe; do
    (cd "$pkg" && "${ZIG:-zig}" build-obj -O $mode -femit-asm="$PWD/../iv-$mode.s" -fno-emit-bin __rig_main.zig) >build.log 2>&1 || fail "$mode asm iv: $(cat build.log)"
    python3 check.py iv-accounts.txt "$pkg/../iv-$mode.s" -- 300000 '`chain`=chain' '`generic`=generic' '`values`=values' '`method`=method' '`loop`=loop' '`byvalue`=byvalue' || fail "$mode"
    # `wrapped` and `piled` check what the rule leaves out of line, which
    # holds the marked functions: in debug Zig inlines only an `inline
    # fn`, while in --release LLVM inlines unmarked functions of its own
    # accord.
    [[ $mode == Debug ]] || continue
    python3 check.py iv-accounts.txt "$pkg/../iv-$mode.s" -- 0 '`wrapped`=wrapped' '`piled`=piled' || fail "$mode"
    python3 check.py iv-accounts.txt "$pkg/../iv-$mode.s" -- 40000 '`byrule`=byrule' || fail "$mode"
done
exit 0
