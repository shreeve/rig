# RIG_NO_CRASH_REPORT=1 only stops a crash report (macOS's, or Linux's
# crash handler, apport): a panicking program exits with the same status
# (134, SIGABRT) and writes the same stdout and stderr with it as without
# it, in every build mode, and `rig test` reports a panicking test the
# same. On Linux it is the program's own core limit of exactly 1; on
# macOS, the process that starts it answers its crash (below), as `rig
# run` and `rig test` always do. It builds in all four modes, which on a
# loaded machine takes longer than the default limit.
# timeout: 600
source "$ROOT/test/cli/_lib.sh"

# The stderr of a run, less what differs between any two runs: the
# thread's id and the stack trace's addresses.
stable() { sed -E 's/thread [0-9]+/thread N/; s/0x[0-9a-f]+/0xN/g' "$1"; }

cat >boom.rig <<'EOF2'
fun rt(n: Int) -> Int
  n

sub main()
  print("before")
  a = [1, 2, 3]
  print(a[rt(3)])
EOF2
# On macOS the variable does nothing for a program run directly, so both
# runs go through cpuq's cap (`capped`), which answers their crashes, and
# file no report; elsewhere they run as they are.
proto=$(cpuq cap --protocol 2>/dev/null) || proto=0
[[ $proto =~ ^[0-9]+$ ]] || proto=0
capped() {
    if [[ $(uname -s) == Darwin ]] && (( proto >= 3 )); then
        cpuq cap --no-crash-report -- "$@"
    else
        "$@"
    fi
}
for mode in debug release release=safe release=fast; do
    flag=""; [[ $mode == debug ]] || flag=--$mode
    exe=boom-${mode//=/-}
    rig build $flag -o "$exe" boom.rig >build.log 2>&1 || fail "build $mode: $(cat build.log)"
    capped "./$exe" >out.txt 2>err.txt; rc=$?
    RIG_NO_CRASH_REPORT=1 capped "./$exe" >quiet_out.txt 2>quiet_err.txt; quiet_rc=$?
    expect_rc $rc 134 "$mode without RIG_NO_CRASH_REPORT"
    expect_rc $quiet_rc 134 "$mode with RIG_NO_CRASH_REPORT=1"
    expect_eq "$(cat quiet_out.txt)" "$(cat out.txt)" "$mode stdout"
    expect_eq "$(stable quiet_err.txt)" "$(stable err.txt)" "$mode stderr"
    expect_has "$(cat err.txt)" "index out of bounds" "$mode panic message"
done

cat >tboom.rig <<'EOF2'
fun rt(n: Int) -> Int
  n

test "panics"
  a = [1, 2, 3]
  print(a[rt(3)])
EOF2
rig test tboom.rig >out.txt 2>err.txt; rc=$?
RIG_NO_CRASH_REPORT=1 rig test tboom.rig >quiet_out.txt 2>quiet_err.txt; quiet_rc=$?
expect_rc $quiet_rc $rc "rig test of a panicking test"
expect_eq "$(cat quiet_out.txt)" "$(cat out.txt)" "rig test stdout"
expect_eq "$(stable quiet_err.txt)" "$(stable err.txt)" "rig test stderr"

# Linux: the program's core limit is exactly 1 (soft and hard), at which
# the kernel starts no core_pattern pipe; without the variable it keeps
# the limit it was given.
if [[ $(uname -s) == Linux ]]; then
    cat >limits.rig <<'EOF2'
use std.file

sub main()
  if file.read("/proc/self/limits") as s
    print(s)
  else
    print("none")
EOF2
    core() { awk '/^Max core file size/ { print $5, $6 }'; }
    got=$(RIG_NO_CRASH_REPORT=1 rig run limits.rig 2>&1 | core)
    expect_eq "$got" "1 1" "the core limit with RIG_NO_CRASH_REPORT=1"
    want=$(core </proc/$$/limits)
    got=$(rig run limits.rig 2>&1 | core)
    expect_eq "$got" "$want" "the core limit without RIG_NO_CRASH_REPORT"
fi

# macOS: a panic run quiet (the harness's `quiet`, through cpuq's cap) files no crash report, by
# the user's ReportCrash (~/Library/Logs/DiagnosticReports) or the system's
# (/Library/Logs/DiagnosticReports), and neither does a panic under `rig run`, which answers its
# program's crash itself, with or without RIG_NO_CRASH_REPORT; a built program's panic not run
# quiet still files one: the control, the one report this test files. Each built program is unique
# and named for the run (ReportCrash files little for a binary it has seen crash, and reports go
# by program name). `rig run`'s programs all share one name, so its report is told by its parent's
# pid, the `rig run` process's (`zig run` replaces itself with the program). The control shows
# this Mac files reports at all (a CI runner may not); without one the checks are skipped, and the
# cap check without a cpuq that answers crashes (cap protocol 3).
if [[ $(uname -s) == Darwin ]]; then
    tag=$RANDOM$RANDOM
    for k in q c r; do
        cat >"crash_${k}_$tag.rig" <<EOF2
fun rt(n: Int) -> Int
  n

sub main()
  print("$k $tag")
  a = [1, 2, 3]
  print(a[rt(3)])
EOF2
        [[ $k == r ]] || rig build -o "crash_${k}_$tag" "crash_${k}_$tag.rig" >build.log 2>&1 || fail "build crash_$k: $(cat build.log)"
    done
    reports() { ls ~/Library/Logs/DiagnosticReports /Library/Logs/DiagnosticReports 2>/dev/null | grep -c "^$1-"; }
    by_parent() { grep -lw "\"parentPid\" : $1" ~/Library/Logs/DiagnosticReports/__rig_main-* /Library/Logs/DiagnosticReports/__rig_main-* 2>/dev/null | wc -l | tr -d ' '; }
    rig run "crash_r_$tag.rig" >/dev/null 2>&1 &
    run_pid=$!
    wait $run_pid; expect_rc $? 134 "a panic under rig run"
    (( proto >= 3 )) && { quiet "./crash_q_$tag" >/dev/null 2>&1; expect_rc $? 134 "a panic run quiet"; }
    "./crash_c_$tag" >/dev/null 2>&1; expect_rc $? 134 "a panic not run quiet"
    for _ in $(seq 1 40); do (( $(reports "crash_c_$tag") > 0 )) && break; sleep 1; done
    if (( $(reports "crash_c_$tag") > 0 )); then
        (( proto >= 3 )) && expect_eq "$(reports "crash_q_$tag")" 0 "crash reports, user and system, for a panic run quiet"
        expect_eq "$(by_parent $run_pid)" 0 "crash reports, user and system, for a panic under rig run"
    else
        echo "note: this Mac filed no report for the control panic in 40 s: the quiet checks are skipped"
    fi
fi
exit 0
