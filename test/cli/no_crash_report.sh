# RIG_NO_CRASH_REPORT=1 only stops macOS from filing a crash report: a
# panicking program exits with the same status (134, SIGABRT) and writes
# the same stdout and stderr with it as without it, in every build mode,
# and `rig test` reports a panicking test the same.
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
for mode in debug release release=safe release=fast; do
    flag=""; [[ $mode == debug ]] || flag=--$mode
    exe=boom-${mode//=/-}
    rig build $flag -o "$exe" boom.rig >build.log 2>&1 || fail "build $mode: $(cat build.log)"
    "./$exe" >out.txt 2>err.txt; rc=$?
    RIG_NO_CRASH_REPORT=1 "./$exe" >quiet_out.txt 2>quiet_err.txt; quiet_rc=$?
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
exit 0
