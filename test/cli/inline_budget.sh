# timeout: 1500
# Zig charges every inline call, Rig's inlined functions and the runtime's
# `inline fn` helpers (`rig.addProven`, ...) alike, to the compile-time
# evaluation budget of the function the code lands in, and fails a build
# that passes it. Every emitted function that is not inline raises it
# first (`rig.eval_quota`), so no count of inline calls stops a build. A
# grid of call counts x shape x mode (debug, --release): each program must
# build and print what the same program prints with the calls spelled out
# by hand.
#   plain   N calls of an inlined helper
#   value   N calls of an inlined instance of a compile-time-value function
#   nested  N calls of an inlined helper that calls another twice
#   proven  one function with N proven adds (`rig.addProven`)
#   helpers N calls of an inlined helper holding six proven adds
#   ctproven the same through an instance (`bump[1]`)
#   forced  N calls of a helper marked `inline`, over the size the
#           compiler inlines by itself, holding twelve proven adds
source "$ROOT/test/cli/_lib.sh"

# The probes of the review that found the class.
for p in budget_proven_adds_plain_fn:26 budget_runtime_inline_helpers:0 regress_ct_instance_proven_adds:0; do
    f=$ROOT/test/corpus/rev154-${p%%:*}.rig
    cp "$f" "${p%%:*}.rig"
    out=$(rig run "${p%%:*}.rig" 2>&1) || fail "debug ${p%%:*}: $out"
    expect_eq "$out" "${p##*:}" "debug ${p%%:*}"
    rig build --release -o "prog_${p%%:*}" "${p%%:*}.rig" >build.log 2>&1 || fail "release ${p%%:*}: $(cat build.log)"
    out=$(./"prog_${p%%:*}" 2>&1) || fail "release ${p%%:*} ran: $out"
    expect_eq "$out" "${p##*:}" "release ${p%%:*}"
done

six='  if i + 1 <= s.len
    i += 1
  if i + 1 <= s.len
    i += 1
  if i + 1 <= s.len
    i += 1
  if i + 1 <= s.len
    i += 1
  if i + 1 <= s.len
    i += 1
  if i + 1 <= s.len
    i += 1'

for n in 100 1000 5000; do
    for shape in plain value nested proven helpers ctproven forced; do
        {
            echo 'fun inc(x: Int) -> Int'
            echo '  x + 1'
            echo
            echo 'fun step[k: Int](x: Int) -> Int'
            echo '  inc(x) + k - 1'
            echo
            echo 'fun twice(x: Int) -> Int'
            echo '  inc(inc(x))'
            echo
            echo 'fun bump(s: ?String, at: Int) -> Int'
            echo '  i = at'
            echo "$six"
            echo '  i - at'
            echo
            echo 'fun cbump[k: Int](s: ?String, at: Int) -> Int'
            echo '  i = at'
            echo "$six"
            echo '  i - at + k - 1'
            echo
            echo 'inline fun fbump(s: ?String, at: Int) -> Int'
            echo '  i = at'
            echo "$six"
            echo "$six"
            echo '  i - at'
            echo
            echo 'fun many(s: ?String) -> Int'
            echo '  i = 0'
            if [[ $shape == proven ]]; then
                for _ in $(seq 1 "$n"); do printf '  if i + 1 <= s.len\n    i += 1\n'; done
            fi
            echo '  i'
            echo
            echo 'sub main()'
            echo '  s = "abcdefghijklmnopqrstuvwxyz"'
            echo '  n = 0'
            for _ in $(seq 1 "$n"); do
                case $shape in
                    plain) echo '  n = inc(n)' ;;
                    value) echo '  n = step[1](n)' ;;
                    nested) echo '  n = twice(n)' ;;
                    helpers) echo '  n = n + bump(s, 0)' ;;
                    ctproven) echo '  n = n + cbump[1](s, 0)' ;;
                    forced) echo '  n = n + fbump(s, 0)' ;;
                esac
            done
            echo '  print(n + many(s))'
        } >"b_${shape}_$n.rig"
        case $shape in
            nested) want=$((2 * n)) ;;
            proven) want=$((n < 26 ? n : 26)) ;;
            helpers | ctproven) want=$((6 * n)) ;;
            forced) want=$((12 * n)) ;;
            *) want=$n ;;
        esac
        out=$(rig run "b_${shape}_$n.rig" 2>&1) || fail "debug $shape $n: $out"
        expect_eq "$out" "$want" "debug $shape $n"
        # Zig's budget is spent in analysis, which debug runs too, so
        # --release adds only LLVM's time; at 5,000 calls that is minutes
        # per program (over 25 for one out-of-line instance), so the
        # largest count is built in debug only.
        [[ $n == 5000 ]] && continue
        # --release at 1,000 calls runs only with INLINE_BUDGET_FULL=1 (the
        # full gates), to fit a CI shard.
        [[ $n == 1000 && -z "${INLINE_BUDGET_FULL:-}" ]] && continue
        rig build --release -o "prog_${shape}_$n" "b_${shape}_$n.rig" >build.log 2>&1 || fail "release $shape $n: $(cat build.log)"
        out=$(./"prog_${shape}_$n" 2>&1) || fail "release $shape $n ran: $out"
        expect_eq "$out" "$want" "release $shape $n"
    done
done

# No count of calls stops inlining: 300 calls of a helper leave it
# inlined, as do 250 of one holding six proven adds (1,750 inline calls in
# main), and the adds stay proven.
{
    echo 'fun inc(x: Int) -> Int'
    echo '  x + 1'
    echo
    echo 'sub main()'
    echo '  n = 0'
    for _ in $(seq 1 300); do echo '  n = inc(n)'; done
    echo '  print(n)'
} >over.rig
out=$(rig emit over.rig 2>/dev/null) || fail "emit over"
expect_has "$out" 'pub inline fn inc(' "300 calls in one function: inc inlined"
{
    echo 'fun bump(s: ?String, at: Int) -> Int'
    echo '  i = at'
    echo "$six"
    echo '  i - at'
    echo
    echo 'sub main()'
    echo '  s = "abcdefghijklmnopqrstuvwxyz"'
    echo '  n = 0'
    for _ in $(seq 1 250); do echo '  n = n + bump(s, 0)'; done
    echo '  print(n)'
} >under.rig
out=$(rig emit under.rig 2>/dev/null) || fail "emit under"
expect_has "$out" 'pub inline fn bump(' "250 calls of bump: bump inlined"
expect_has "$out" 'rig.addProven(' "bump's adds proven"
out=$(rig run under.rig 2>&1) || fail "debug under: $out"
expect_eq "$out" 1500 "debug under"
rig build --release -o prog_under under.rig >build.log 2>&1 || fail "release under: $(cat build.log)"
out=$(./prog_under 2>&1) || fail "release under ran: $out"
expect_eq "$out" 1500 "release under"

# The marked helper is inlined, over the size limit, its adds proven.
out=$(rig emit b_forced_100.rig 2>/dev/null) || fail "emit forced 100"
expect_has "$out" 'pub inline fn fbump(' "a marked helper over the size limit"
[[ $(grep -c 'rig.addProven(' <<<"$out") -ge 12 ]] || fail "forced: fbump's adds not proven"

# Each function that is not inline raises its budget first; an inline
# one runs on its caller's.
out=$(rig emit b_proven_1000.rig 2>/dev/null) || fail "emit proven 1000"
[[ $(grep -c 'rig.addProven(' <<<"$out") -ge 1000 ]] || fail "1000 adds in many: not all proven"
# `main`'s body is `__rig_run_main`, which `main` runs on the program's
# stack.
for f in "fn __rig_run_main" "pub fn many"; do
    grep -A1 -E "^$f\(" <<<"$out" | grep -qF '@setEvalBranchQuota(rig.eval_quota);' || fail "$f does not raise its budget first"
done
grep -A1 -F 'pub inline fn ' <<<"$out" | grep -qF '@setEvalBranchQuota' && fail "an inline function sets the budget"
true
