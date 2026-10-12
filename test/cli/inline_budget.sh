# timeout: 900
# Zig counts every inlined call against the compile-time evaluation budget
# of the function it is in, and fails a build that passes it. A function
# that holds more inlined calls than inlining.max_inlined_calls (256), its
# own and those inside the inlined bodies, calls the function it calls most
# instead. A grid of call counts x callee shape x mode (debug, --release):
# each program must build and print what the same program prints with the
# calls spelled out by hand.
source "$ROOT/test/cli/_lib.sh"

for n in 100 1000 5000; do
    for shape in plain value nested; do
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
            echo 'sub main()'
            echo '  n = 0'
            for _ in $(seq 1 "$n"); do
                case $shape in
                    plain) echo '  n = inc(n)' ;;
                    value) echo '  n = step[1](n)' ;;
                    nested) echo '  n = twice(n)' ;;
                esac
            done
            echo '  print(n)'
        } >"b_${shape}_$n.rig"
        want=$n
        [[ $shape == nested ]] && want=$((2 * n))
        out=$(rig run "b_${shape}_$n.rig" 2>&1) || fail "debug $shape $n: $out"
        expect_eq "$out" "$want" "debug $shape $n"
        rig build --release -o "prog_${shape}_$n" "b_${shape}_$n.rig" >build.log 2>&1 || fail "release $shape $n: $(cat build.log)"
        out=$(./"prog_${shape}_$n" 2>&1) || fail "release $shape $n ran: $out"
        expect_eq "$out" "$want" "release $shape $n"
    done
done

# Few calls stay inlined; many are calls.
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
grep -qF 'pub fn inc(' <<<"$out" || fail "300 calls in one function: inc should be called"
