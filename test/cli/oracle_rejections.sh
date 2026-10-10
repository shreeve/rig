#!/bin/bash
# `rig-oracle --rejects`: a function the oracle rejects must be listed
# (UNLISTED fails the run), and a listed one it no longer rejects fails
# the run (LOST), whatever the compiler decides, so a weaker reference
# checker shows. A listed rejection it keeps passes.
source "$ROOT/test/cli/_lib.sh"
ORACLE="$ROOT/bin/rig-oracle"
[[ -x $ORACLE ]] || fail "bin/rig-oracle is not built"

# `bad` writes `v` while a read view of it lives: both checkers reject
# it. `good` is accepted by both.
cat >p.rig <<'RIG'
sub bad()
  v: Vec[Int] = Vec()
  r = ?v
  !v.push(1)
  print(r.len)

sub good()
  v: Vec[Int] = Vec()
  !v.push(1)
  print(v.len)

sub main()
  good()
RIG

# Listed and still rejected: the run passes.
printf 'p.rig bad\n' >kept
out=$("$ORACLE" --rejects kept p.rig 2>&1); rc=$?
expect_rc $rc 0 "a kept rejection"

# Not listed: UNLISTED fails the run.
: >none
out=$("$ORACLE" --rejects none p.rig 2>&1); rc=$?
expect_rc $rc 1 "an unlisted rejection"
expect_has "$out" "UNLISTED p.rig bad" "an unlisted rejection"

# Listed, but the oracle accepts it: LOST fails the run.
printf 'p.rig bad\np.rig good\n' >lost
out=$("$ORACLE" --rejects lost p.rig 2>&1); rc=$?
expect_rc $rc 1 "a lost rejection"
expect_has "$out" "LOST p.rig good" "a lost rejection"
exit 0
