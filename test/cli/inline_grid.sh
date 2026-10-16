# timeout: 900
# What an inlined function hands back is a run-time value to its caller:
# a result that no argument decides (a constant, a parameter it ignores,
# another inlined call, an empty optional, an error) must not let Zig fold
# the arithmetic, indexing, narrowing, or shift on it into a compile error
# in code the program never runs, and the same use, run, must panic. A grid
# of callee shape x use x mode (debug, --release): each shape gets one
# program with every use in a branch that does not run, and each cell one
# program that runs the use.
source "$ROOT/test/cli/_lib.sh"
source "$ROOT/test/cli/_inline_grid.sh"

inline_grid_write

for mode in debug release; do
    for f in unreached_*.rig; do
        if [[ $mode == debug ]]; then
            out=$(rig run "$f" 2>&1) || fail "$mode $f: $out"
        else
            rig build --release -o "prog_${f%.rig}" "$f" >build.log 2>&1 || fail "release $f: $(cat build.log)"
            out=$(./"prog_${f%.rig}" 2>&1) || fail "release $f ran: $out"
        fi
        case $f in
            unreached_optional.rig|unreached_failing.rig|unreached_var.rig) expect_eq "$out" "ok" "$mode $f" ;;
            *) expect_eq "$out" $'3\nok' "$mode $f" ;;
        esac
    done
    if [[ $mode == debug ]]; then out=$(rig run ctvalues.rig 2>&1) || fail "$mode ctvalues: $out"
    else
        rig build --release -o prog_ctvalues ctvalues.rig >build.log 2>&1 || fail "release ctvalues: $(cat build.log)"
        out=$(./prog_ctvalues 2>&1) || fail "release ctvalues ran: $out"
    fi
    expect_eq "$out" $'15 5 3 6\n20 10' "$mode ctvalues"
    # A use that runs panics the same in both modes. The --release builds
    # of them are the slowest part of the grid, so they run in three
    # shards of their own, inline_grid_release_{1,2,3}.sh, and only with
    # INLINE_GRID_FULL=1 (the full gates); a CI shard runs the debug ones.
    [[ $mode == release ]] && continue
    for f in reached_*.rig; do
        out=$(RIG_NO_CRASH_REPORT=1 rig run "$f" 2>&1) && fail "$mode $f should panic: $out"
        expect_has "$out" "panic" "$mode $f"
    done
done
