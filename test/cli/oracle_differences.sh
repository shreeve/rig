#!/bin/bash
# `rig-oracle --allow`: a function the compiler rejects and the oracle
# accepts must be listed (STRICTER fails the run), and a listed one that
# is gone fails the run (FIXED), so the list stays exact.
source "$ROOT/test/cli/_lib.sh"
ORACLE="$ROOT/bin/rig-oracle"
[[ -x $ORACLE ]] || fail "bin/rig-oracle is not built"

# `twice` calls a `once` closure twice: the compiler rejects it, and the
# oracle does not read `once`. `main` is accepted by both.
cat >p.rig <<'RIG'
fun twice(f: once ?fun() -> Int) -> Int
  f() + f()

sub main()
  print(1)
RIG

# Listed: the run passes.
printf 'p.rig twice prod-rejects ref-gap `once`\n' >listed
out=$("$ORACLE" --allow listed p.rig 2>&1); rc=$?
expect_rc $rc 0 "a listed difference"

# Not listed: STRICTER fails the run and names the entry.
: >none
out=$("$ORACLE" --allow none p.rig 2>&1); rc=$?
expect_rc $rc 1 "an unlisted difference"
expect_has "$out" "STRICTER p.rig twice" "an unlisted difference"
expect_has "$out" "p.rig twice prod-rejects CLASS NOTE" "an unlisted difference"

# Listed, but the compiler accepts it: FIXED fails the run.
printf 'p.rig twice prod-rejects ref-gap `once`\np.rig main prod-rejects ref-gap gone\n' >gone
out=$("$ORACLE" --allow gone p.rig 2>&1); rc=$?
expect_rc $rc 1 "a gone difference"
expect_has "$out" "FIXED p.rig main" "a gone difference"
exit 0
