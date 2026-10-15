# timeout: 900
# Each frame owner's account (`rig check --facts=frames`: its own reach
# and what the functions the rule inlines into it add) against the stack
# Zig's code reserves for it, in debug, for every kind of owner (a
# function, each instance of a generic one, a closure, a test block, a
# `drop` body, `main`) and every body that belongs to the owner around it
# (a `defer` body at each exit, a match arm), each with the calls of a
# 16 KB helper the rule inlines: an account lower than the real frame by
# more than 4 KiB fails. The real frame is the prologue's reservation,
# read from the assembly Zig writes for aarch64, so the test runs on an
# aarch64 Mac only. A --release build is left out: LLVM inlines a function
# the rule leaves out of line of its own accord, which no count of Rig's
# models.
source "$ROOT/test/cli/_lib.sh"

if [[ $(uname -s) != Darwin || $(uname -m) != arm64 ]]; then
    echo "skipped: reads aarch64 assembly"
    exit 0
fi

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
pkg=$RIG_OUT_DIR/programs/ev
(cd "$pkg" && "${ZIG:-zig}" build-obj -O Debug -femit-asm="$PWD/../ev-main.s" -fno-emit-bin __rig_main.zig) >build.log 2>&1 || fail "asm: $(cat build.log)"
(cd "$pkg" && "${ZIG:-zig}" build-obj -O Debug -femit-asm="$PWD/../ev-test.s" -fno-emit-bin __rig_test.zig) >build.log 2>&1 || fail "test asm: $(cat build.log)"

python3 - accounts.txt "$pkg/../ev-main.s" "$pkg/../ev-test.s" <<'PY' || exit 1
import re, sys

# Each owner, by its label, and the functions Zig writes for it.
owners = {
    '`gen`': r'gen__func_\d+',
    '`drop`': r'Res\.__rig_user_drop',
    '`plain`': r'plain',
    'a closure': r'closure__struct_\d+\.__rig_invoke',
    '`later`': r'later',
    '`arm`': r'arm',
    'test "pile"': r'__rig_test_0',
    '`main`': r'__rig_run_main',
}

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
for path in sys.argv[2:]:
    real.update(frames(path))
accounts = {}
for line in open(sys.argv[1]):
    # "L:C label bytes reach auto"; a label has spaces.
    head, _, reach, auto = line.rsplit(None, 3)
    accounts[head.split(None, 1)[1]] = int(reach) + int(auto)
bad = []
for label, pattern in owners.items():
    if label not in accounts:
        bad.append(f'{label}: no account')
        continue
    if accounts[label] < 16000:
        bad.append(f'{label}: the helper is not inlined into it (account {accounts[label]})')
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
exit 0
