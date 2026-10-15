# timeout: 900
# The stack a function's code takes is at most `sema.reach_factor` times
# its reach (`rig check --facts=frames`, its last column): the bound that
# keeps every frame the compiler accepts within the guard below the
# program's stack (docs/INTERNALS.md, "The program's stack"). This builds
# each form that makes or copies a value (a fill, a place, a field, an
# element, a call, `if`, `??`, `catch`, `+x`) in each context that takes
# one (a binding, an assignment, a field or element store, an argument,
# a constructor, an enum payload, an optional, an array, a branch, a
# return), and checks the bound against the stack each frame reserves,
# in debug and release builds: Zig's aarch64 assembly on an aarch64 Mac,
# and the program's x86_64 code (objdump) on Linux.
source "$ROOT/test/cli/_lib.sh"

case "$(uname -s)/$(uname -m)" in
    Darwin/arm64) how=asm ;;
    Linux/x86_64)
        command -v objdump >/dev/null || { echo "skipped: no objdump"; exit 0; }
        how=objdump ;;
    *) echo "skipped: reads aarch64 assembly or x86_64 code"; exit 0 ;;
esac

factor=$(sed -n 's/^pub const reach_factor: u64 = \([0-9]*\);.*/\1/p' "$ROOT/src/sema.zig")
[[ -n $factor ]] || fail "no reach_factor in src/sema.zig"

python3 - >grid.rig <<'PY'
N = 8192
print(f'''type A = [{N}]Int

obj P
  a: A
  b: Int

enum S
  one(v: A)
  nothing

error Bad
  bad

fun make(k: Int) -> A
  [{N} of k]

fun maybe(k: Int) -> A?
  return none if k < 0
  make(k)

fun fails(k: Int) -> A!
  return Bad.bad if k < 0
  make(k)

fun take(a: A) -> Int
  a[3]

fun look(a: ?A) -> Int
  a[3]

fun takeP(p: P) -> Int
  p.a[3] + p.b
''')
forms = {
    'fill_rt': ([], f'[{N} of i]'),
    'fill_ct': ([], f'[{N} of 7]'),
    'place': ([f'x = [{N} of 1]'], 'x'),
    'field': ([f'p = P(a: [{N} of 1], b: 2)'], 'p.a'),
    'elem': ([f'xs = [[{N} of 1], [{N} of 2]]'], 'xs[i % 2]'),
    'call': ([], 'make(i)'),
    'if_place': ([f'x = [{N} of 1]', f'y = [{N} of 2]'], 'x if i > 2 else y'),
    'if_fill': ([], f'[{N} of i] if i > 2 else [{N} of 0]'),
    'orelse': ([f'x = [{N} of 1]'], 'maybe(i) ?? x'),
    'catch': ([f'x = [{N} of 1]'], 'fails(i) catch x'),
    'clone': ([f'x = [{N} of 1]'], '+x'),
}
contexts = {
    'bind': lambda e: [f'v = {e}', 'print(v[i])'],
    'typed': lambda e: [f'v: A = {e}', 'print(v[i])'],
    'rebind': lambda e: [f'v = [{N} of 3]', 'print(v[i])', f'v = {e}', 'print(v[i])'],
    'fieldset': lambda e: [f'q = P(a: [{N} of 3], b: 1)', f'q.a = {e}', 'print(q.a[i])'],
    'elemset': lambda e: [f'zs = [[{N} of 3], [{N} of 4]]', f'zs[i % 2] = {e}', 'print(zs[0][i])'],
    'arg': lambda e: [f'print(take({e}))'],
    'ctor': lambda e: [f'q = P(a: {e}, b: 1)', 'print(takeP(q))'],
    'enum': lambda e: [f's = S.one({e})', 'match s', '  .one(w) => print(w[i])', '  .nothing => print(0)'],
    'optbind': lambda e: [f'v: A? = {e}', 'if v as w', '  print(w[i])'],
    'array': lambda e: [f'v = [{e}, [{N} of 0]]', 'print(v[1][i])'],
    'branch': lambda e: [f'v = {e} if i > 1 else [{N} of 0]', 'print(v[i])'],
}
returns = {'ret': 'A', 'retopt': 'A?', 'reterr': 'A!'}
calls = []
for fn, (setup, e) in forms.items():
    for cn, ctx in contexts.items():
        print(f'called sub {fn}__{cn}(i: Int)')
        for line in setup + ctx(e):
            print(f'  {line}')
        print()
        calls.append(f'{fn}__{cn}(3)')
    for cn, rt in returns.items():
        print(f'called fun {fn}__{cn}(i: Int) -> {rt}')
        for line in setup + [e]:
            print(f'  {line}')
        print()
        use = {'A': f'{fn}__{cn}(3)[3]', 'A?': f'({fn}__{cn}(3) ?? [{N} of 0])[3]', 'A!': f'({fn}__{cn}(3) catch [{N} of 0])[3]'}[rt]
        print(f'called sub use_{fn}__{cn}()\n  print({use})\n')
        calls.append(f'use_{fn}__{cn}()')
print('called sub viewarg(i: Int)')
print(f'  x = [{N} of 1]')
print('  print(look(x) + i)\n')
calls.append('viewarg(3)')
print('sub main()')
for c in calls:
    print(f'  {c}')
PY
"$RIG" check --facts=frames grid.rig >counts.txt 2>check.txt || fail "grid.rig is rejected: $(head -5 check.txt)"

if [[ $how == asm ]]; then
    rig emit grid.rig >/dev/null 2>&1 || fail "emit grid.rig"
    pkg=$RIG_OUT_DIR/programs/grid
    for mode in Debug ReleaseSafe; do
        (cd "$pkg" && "${ZIG:-zig}" build-obj -O $mode -femit-asm="$PWD/../grid-$mode.s" -fno-emit-bin __rig_main.zig) >build.log 2>&1 || fail "$mode assembly: $(cat build.log)"
        python3 "$ROOT/test/cli/_frames.py" "$RIG_OUT_DIR/programs/grid-$mode.s" >"real-$mode.txt"
    done
else
    for mode in Debug ReleaseSafe; do
        flag=; [[ $mode == ReleaseSafe ]] && flag=--release
        rig build $flag -o "grid-$mode" grid.rig >build.log 2>&1 || fail "build $mode: $(cat build.log)"
        objdump -d -M intel --no-show-raw-insn "grid-$mode" >"grid-$mode.dis"
        python3 "$ROOT/test/cli/_frames.py" "grid-$mode.dis" >"real-$mode.txt"
    done
fi

# A function's real frame against `factor` times its reach, with 16 KiB
# for the registers and scalars every frame saves. A release build
# inlines some of these functions into their callers; each that is left
# is checked.
python3 - "$factor" counts.txt real-Debug.txt real-ReleaseSafe.txt <<'PY' || exit 1
import sys
factor = int(sys.argv[1])
reach = {}
for line in open(sys.argv[2]):
    _, label, _, r = line.split()
    reach[label.strip('`')] = int(r)
bad = []
for path in sys.argv[3:]:
    real = dict((n, int(b)) for n, b in (l.split() for l in open(path)))
    measured = [n for n in reach if n in real]
    if 'Debug' in path and len(measured) < 150:
        bad.append(f'{path}: only {len(measured)} of {len(reach)} functions found')
    for n in measured:
        if real[n] > factor * reach[n] + 16384:
            bad.append(f'{path}: `{n}` reserves {real[n]} bytes; its reach is {reach[n]}, times {factor} is {factor * reach[n]}')
if bad:
    print('FAIL: ' + '\n'.join(bad))
    sys.exit(1)
PY
exit 0
