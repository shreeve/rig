# A closed stdout pipe (`rig test f.rig | head`) ends a program quietly
# with status 0, but never turns a failure into success: a program that
# panics, and a `rig test` run cut off before its summary, exit non-zero.
# builds: shared
source "$ROOT/test/cli/_lib.sh"

printf 'test "ok"\n  print("fine")\n\ntest "bad"\n  panic("boom")\n' >failing.rig
rig test failing.rig 2>/dev/null | (exec 0<&-; sleep 1)
expect_rc "${PIPESTATUS[0]}" 1 "rig test with a failing test and a closed stdout"

printf 'sub main()\n  print("fine")\n  panic("boom")\n' >panics.rig
rig run panics.rig 2>/dev/null | (exec 0<&-; sleep 1)
[[ ${PIPESTATUS[0]} -ne 0 ]] || fail "a panic with a closed stdout exits 0"

printf 'sub main()\n  print("fine")\n' >plain.rig
rig run plain.rig 2>/dev/null | (exec 0<&-; sleep 1)
expect_rc "${PIPESTATUS[0]}" 0 "a program with a closed stdout"
exit 0
