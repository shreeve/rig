# timeout: 360
# Zig charges every inline call, Rig's inlined functions and the runtime's
# `inline fn` helpers (`rig.addProven`, ...) alike, to the compile-time
# evaluation budget of the function the code lands in, and fails a build
# that passes it. Every emitted function that is not inline raises it
# first (`rig.eval_quota`), so no count of inline calls stops a build. A
# grid of call counts x shape x mode (debug, --release): each program must
# build and print what the same program prints with the calls spelled out
# by hand. tools/inline_budget.py writes the programs (its shapes are
# listed there) and test/rig/emit-inline-budget.rig.test, which holds the
# probes of the review that found the class and what rig emits for them.
#
# The default run builds every shape in one program, 1,000 calls of each,
# past Zig's own budget of 1,000 many times over, in debug, where Zig
# spends the budget, and 100 of each with --release. INLINE_BUDGET_FULL=1
# builds each shape alone at 100, 1,000, and 5,000 calls in debug, and at
# 100 and 1,000 with --release.
source "$ROOT/test/cli/_lib.sh"

gen=$ROOT/tools/inline_budget.py

# build <n> <shape> <mode>: build and run the grid's program, and check
# what it prints.
build() {
    local f=b_$2_$1 want out
    python3 "$gen" grid "$1" "$2" >"$f.rig" || fail "write $f.rig"
    want=$(python3 "$gen" want "$1" "$2")
    if [[ $3 == debug ]]; then
        out=$(rig run "$f.rig" 2>&1) || fail "debug $2 $1: $out"
    else
        rig build --release -o "prog_$f" "$f.rig" >build.log 2>&1 || fail "release $2 $1: $(cat build.log)"
        out=$(./"prog_$f" 2>&1) || fail "release $2 $1 ran: $out"
    fi
    expect_eq "$out" "$want" "$3 $2 $1"
}

if [[ -z "${INLINE_BUDGET_FULL:-}" ]]; then
    build 1000 all debug
    build 100 all release
    exit 0
fi

for n in 100 1000 5000; do
    for shape in plain value nested proven helpers ctproven forced; do
        build "$n" "$shape" debug
        # Zig's budget is spent in analysis, which debug runs too, so
        # --release adds only LLVM's time; at 5,000 calls that is minutes
        # per program (over 25 for one out-of-line instance), so the
        # largest count is built in debug only.
        [[ $n == 5000 ]] || build "$n" "$shape" release
    done
done
true
