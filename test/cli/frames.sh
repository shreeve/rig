# timeout: 120
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
# out of line of its own accord, which no count of Rig's models. The two
# programs are cases of test/rig/emit-frames.rig.test, which check what
# they print; this reads them from the cases' tree ($RIG_TESTS).
source "$ROOT/test/cli/_lib.sh"

if [[ $(uname -s) != Darwin || $(uname -m) != arm64 ]]; then
    echo "skipped: reads aarch64 assembly"
    exit 0
fi
[[ -n ${RIG_TESTS:-} ]] || fail "RIG_TESTS is not set: run this script with test/rig.rip"
cp "$RIG_TESTS/behavior/emit/frames_every_owner.rig" ev.rig || fail "no case \`frames every owner\` in $RIG_TESTS"
cp "$RIG_TESTS/behavior/emit/frames_inline_callers.rig" iv.rig || fail "no case \`frames inline callers\` in $RIG_TESTS"

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

# An owner of every kind; its test block passes under `rig test`.
out=$(rig test ev.rig 2>&1) || fail "test: $out"
expect_has "$out" "1 passed, 0 failed" "test"
rig check --tests --facts=frames ev.rig >accounts.txt 2>&1 || fail "facts: $(cat accounts.txt)"
rig emit ev.rig >/dev/null 2>&1 || fail "emit"
pkg=$RIG_OUT_DIR/programs/ev
# The emitted module holds its tests' functions, which only the table of
# tests names: naming the table in the module has Zig compile them too,
# in the one build.
echo 'comptime { _ = &__rig_tests; }' >>"$pkg/__rig_main.zig"
(cd "$pkg" && zig_once "$PWD/../ev.s" -- . -- "${ZIG:-zig}" build-obj -O Debug -femit-asm="$PWD/../ev.s" -fno-emit-bin __rig_main.zig) >build.log 2>&1 || fail "asm: $(cat build.log)"
python3 check.py accounts.txt "$pkg/../ev.s" -- 16000 \
    '`gen`=gen__func_\d+' \
    '`drop`=Res\.__rig_user_drop' \
    '`plain`=plain' \
    'a closure=closure__struct_\d+\.__rig_invoke' \
    '`later`=later' \
    '`arm`=arm' \
    'test "pile"=__rig_test_0' \
    '`main`=__rig_run_main' || exit 1

# Owners that call marked `inline` functions.
rig check --facts=frames iv.rig >iv-accounts.txt 2>&1 || fail "facts iv: $(cat iv-accounts.txt)"
rig emit iv.rig >/dev/null 2>&1 || fail "emit iv"
pkg=$RIG_OUT_DIR/programs/iv
for mode in Debug ReleaseSafe; do
    (cd "$pkg" && zig_once "$PWD/../iv-$mode.s" -- . -- "${ZIG:-zig}" build-obj -O $mode -femit-asm="$PWD/../iv-$mode.s" -fno-emit-bin __rig_main.zig) >build.log 2>&1 || fail "$mode asm iv: $(cat build.log)"
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
