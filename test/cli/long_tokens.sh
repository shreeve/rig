# A token of any length: string literals, names, numbers, and comments
# over 65534 bytes lex as what they are, run sanitizer-clean in debug and
# --release, and diagnostics after or inside one stand at the right line
# and column. Every command the CLI has reads them without panicking. The
# programs are generated here, not kept in the repository.
source "$ROOT/test/cli/_lib.sh"
export RIG_SANITIZE=1

python3 -I - <<'EOF' || fail "generating the programs"
def h(bs):
    x = 0
    for b in bs:
        x = (x * 31 + b) % 2**64
    return x

def dq(n):
    # Raw `abcdefghij\n\x41\"` is the 13 bytes "abcdefghij", LF, "A", '"'.
    unit, val = 'abcdefghij\\n\\x41\\"', b'abcdefghij\nA"'
    k = n // len(unit)
    return '"' + unit * k + 'z' * (n - k * len(unit)) + '"', val * k + b'z' * (n - k * len(unit))

def sq(n):
    unit, val = "klmno''pq", b"klmno'pq"
    k = n // len(unit)
    return "'" + unit * k + 'y' * (n - k * len(unit)) + "'", val * k + b'y' * (n - k * len(unit))

# Token lengths 65534 to 65538 straddle the 65535 that stands for longer.
sizes = [65532, 65533, 65534, 65535, 65536, 1 << 20]
name = 'n' + 'x' * 69999
kind_name = 'K' + 'k' * 69999
lines = ['fun hash(s: ?String) -> U64', '  h: U64 = 0', '  for b in s', '    h = h *% 31 +% U64(b)', '  h', '',
         f'obj {kind_name}', '  v: Int', '', 'sub main()']
want = []
lines.append('  # ' + 'c' * 70000)
for i, n in enumerate(sizes):
    for kind, make in (('d', dq), ('s', sq)):
        lit, val = make(n)
        lines.append(f'  {kind}{i} = {lit}  # ' + 'c' * 70000)
        lines.append(f'  print({kind}{i}.len, hash(?{kind}{i}))')
        want.append(f'{len(val)} {h(val)}')
lines.append(f'  {name} = 7')
lines.append(f'  print({name} + 1)')
want.append('8')
lines.append(f'  k = {kind_name}(v: 5)')
lines.append('  print(k.v)')
want.append('5')
lines.append('  print(0x' + '0' * 70000 + '2a + 0)')
want.append('42')
lines.append('  m = (1 +  # ' + 'c' * 70000)
lines.append('    2)')
lines.append('  print(m)')
want.append('3')
open('long.rig', 'w').write('\n'.join(lines) + '\n')
open('long.want', 'w').write('\n'.join(want) + '\n')

open('named.rig', 'w').write('test "' + 't' * 70000 + '"\n  print("ran")\n')

a = 'a' * 70000
def bad(file, body):
    open(file, 'w').write('sub main()\n' + body + '\n')
bad('after_same_line.rig', f'  print("{a}", missing)')
bad('after_next_line.rig', f'  s = "{a}"\n  print(s.len, missing)')
bad('bad_escape.rig', f'  s = "{a}\\q"\n  print(s.len)')
bad('control.rig', f'  s = "{a}\x01"\n  print(s.len)')
bad('unterminated.rig', f'  s = "{a}\n  print(s.len)')
bad('bad_number.rig', f'  n = 1{a}\n  print(n)')
bad('unexpected_after.rig', f'  print("{a}" missing)')
bad('unexpected_long.rig', f'  print(1 "{a}")')
bad('foreign_word.rig', f'  {name} 5')
bad('detached.rig', f'  x = - {name}\n  print(x)')
bad('spacing.rig', f'  x = "{a}" +"b"\n  print(x)')

# The source limit is 16 MiB: a literal that fills it is read; one byte
# more is not.
limit = 16 << 20
head = 'sub main()\n  s = "'
tail = '"\n  print(s.len)\n'
open('at_limit.rig', 'w').write(head + 'a' * (limit - len(head) - len(tail)) + tail)
open('over_limit.rig', 'w').write(head + 'a' * (limit + 1 - len(head) - len(tail)) + tail)
EOF

# The values, in debug and --release.
want=$(cat long.want)
out=$(rig run long.rig 2>&1) || fail "rig run long.rig: $(head -c 2000 <<<"$out")"
expect_eq "$out" "$want" "long tokens (debug)"
out=$(rig run --release long.rig 2>&1) || fail "rig run --release long.rig: $(head -c 2000 <<<"$out")"
expect_eq "$out" "$want" "long tokens (--release)"

# Every command reads them.
for mode in "check" "check --facts" "check --facts=sema" "check --facts=storage" tokens parse normalize emit; do
    # shellcheck disable=SC2086
    "$RIG" $mode long.rig >out.txt 2>err.txt || fail "rig $mode: $(head -c 2000 err.txt)"
    grep -q panic err.txt && fail "rig $mode panicked: $(head -c 2000 err.txt)"
done
# The emitted Zig holds the 1 MB literal on one line, and parses.
"$RIG" emit long.rig >long.zig 2>emit.txt || fail "rig emit: $(head -c 2000 emit.txt)"
[[ $(awk 'length > 1048576 { n++ } END { print n + 0 }' long.zig) -ge 1 ]] || fail "rig emit: no line holds the 1 MB literal"
"${ZIG:-zig}" ast-check long.zig >/dev/null 2>ast.txt || fail "the emitted Zig does not parse: $(head -c 2000 ast.txt)"
# The trees show the whole literal.
"$RIG" parse long.rig >tree.txt 2>&1 || fail "rig parse"
[[ $(awk 'length > 1048576 { n++ } END { print n + 0 }' tree.txt) -ge 1 ]] || fail "rig parse: the tree lacks the 1 MB literal"

# A test named by a long string runs.
out=$(rig test named.rig 2>&1) || fail "rig test named.rig: $(head -c 2000 <<<"$out")"
expect_has "$out" "1 passed, 0 failed" "a test with a long name"

# check <file> <line:col> <message>: rejected at that place, no panic.
check() {
    local out rc
    out=$("$RIG" check "$1" 2>&1); rc=$?
    [[ $rc -eq 1 ]] || fail "$1: exit status $rc, expected 1: $(head -c 2000 <<<"$out")"
    grep -q panic <<<"$out" && fail "$1 panicked: $(head -c 2000 <<<"$out")"
    expect_has "$(head -c 300 <<<"$out")" "$1:$2: error: $3" "$1"
}
check after_same_line.rig 2:70013 "use of unbound name"
check after_next_line.rig 3:16 "use of unbound name"
check bad_escape.rig 2:70008 'invalid escape `\q`'
check control.rig 2:70008 "control character in a string"
check unterminated.rig 2:7 "unterminated string"
check bad_number.rig 2:7 "malformed number"
check unexpected_after.rig 2:70012 "unexpected name \`missing\`"
check unexpected_long.rig 2:11 'unexpected `"aaaa'
check foreign_word.rig 2:70004 "unexpected"
check detached.rig 2:7 "a prefix \`-\` touches its operand: write \`-nxxx"
check spacing.rig 2:70010 '`a +"b"`: an operator has the same spacing on both sides'

"$RIG" check at_limit.rig >out.txt 2>&1 || fail "a 16 MiB source: $(head -c 2000 out.txt)"
out=$("$RIG" check over_limit.rig 2>&1); expect_rc $? 1 "a source over 16 MiB"
expect_has "$out" "the file is larger than 16 MiB" "a source over 16 MiB"
