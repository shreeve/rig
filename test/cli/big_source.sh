# Sources past 16 MiB: a program of about 24 MB of string literals in one
# file, and the same literals in a directory module of eight files that
# join to about 24 MB, are checked, built in debug, and run, each step
# in bounded time. One literal is 17 MB, past 2^24 bytes; the others are
# on both sides of the 65535 bytes that stand for a long token. The
# limit itself, 2 GiB, is too large to write here: the compiler's unit
# tests check the arithmetic at it. The programs are generated here,
# not kept in the repository.
source "$ROOT/test/cli/_lib.sh"

python3 -I - <<'EOF' || fail "generating the programs"
import os

def h(bs):
    x = 0
    for b in bs:
        x = (x * 31 + b) % 2**64
    return x

# The source of a literal's unit, with escapes, and the bytes it means.
unit, val = r'(node \"a\"\n (leaf 7)) ', b'(node "a"\n (leaf 7)) '
sizes = [17_000_000] + [1000, 60000, 70000, 300000] * 30
decls, length, sums = [], 0, 0
for i, size in enumerate(sizes):
    k = size // len(unit)
    decls.append(f'd{i} = "{unit * k}"')
    length += len(val) * k
    sums = (sums * 31 + h(val * k)) % 2**64

def main(pre):
    lines = ['fun hash(s: ?String) -> U64', '  h: U64 = 0', '  for b in s', '    h = h *% 31 +% U64(b)', '  h', '',
             'sub main()', '  n = 0', '  h: U64 = 0']
    for i in range(len(decls)):
        lines += [f'  n += {pre}d{i}.len', f'  h = h *% 31 +% hash(?{pre}d{i})']
    return lines + ['  print(n, h)']

os.makedirs('one'); os.makedirs('dir/data')
open('one/main.rig', 'w').write('\n'.join(decls + [''] + main('')) + '\n')
open('dir/main.rig', 'w').write('\n'.join(['use data', ''] + main('data.')) + '\n')
# The 17 MB literal alone in the first file; the rest across seven.
parts = [decls[:1]] + [decls[1 + p::7] for p in range(7)]
for p, part in enumerate(parts):
    open(f'dir/data/part{p}.rig', 'w').write('\n'.join('pub ' + d for d in part) + '\n')
open('want', 'w').write(f'{length} {sums}\n')
EOF

size=$(wc -c <one/main.rig)
(( size > 24000000 )) || fail "one/main.rig is $size bytes, not over 24 MB"
size=$(cat dir/data/*.rig | wc -c)
(( size > 24000000 )) || fail "dir/data is $size bytes, not over 24 MB"
want=$(cat want)

# step <seconds> <what> <command>...: the command passes within the bound;
# its time goes to the log.
step() {
    local limit=$1 what=$2 start=$SECONDS out
    shift 2
    out=$("$TIMEOUT_CMD" "$limit" "$@" 2>&1) || fail "$what: $(head -c 2000 <<<"$out")"
    echo "$what: $((SECONDS - start)) s"
    last=$out
}

for p in one dir; do
    step 15 "rig check $p" "$RIG" check $p/main.rig
    step 45 "rig run $p" env RIG_OUT_DIR="$RIG_OUT_DIR/programs/big_$p" "$RIG" run $p/main.rig
    expect_eq "$last" "$want" "rig run $p"
done
