# A request to end `rig run` or `rig batch run` (SIGTERM, as a test
# runner's time limit sends) ends the program it runs too, which would
# otherwise run on with no parent.
source "$ROOT/test/cli/_lib.sh"

# Output to a file is buffered: enough of it reaches the file at once.
cat >spin.rig <<'EOF2'
sub main()
  for 0..2000
    print("started, and spinning until it is ended")
  n = 0
  while n >= 0
    n = (n + 1) % 1000
EOF2

# Whatever this test starts goes when it ends, however it ends.
rp= cp=
trap 'kill -9 $rp $cp 2>/dev/null' EXIT

# Start `rig` with `$@`, wait for the program to print, end `rig` with
# SIGTERM, and check that the program is gone. `rig` runs as itself, not
# through the wrapper, so `$!` is its process.
ends() {
  local what=$1; shift
  rm -f out.txt
  cp=
  RIG_OUT_DIR="$RIG_OUT_DIR/programs/run_ends" "$RIG" "$@" >out.txt 2>&1 &
  rp=$!
  for _ in $(seq 1 3000); do grep -q started out.txt 2>/dev/null && break; sleep 0.1; done
  grep -q started out.txt || fail "$what: the program never started: $(head -3 out.txt)"
  cp=$(pgrep -P "$rp" | head -1)
  [[ -n "$cp" ]] || fail "$what: no program under rig"
  kill -TERM "$rp"
  wait "$rp"
  expect_rc $? 143 "$what ends as the program does"
  for _ in $(seq 1 50); do kill -0 "$cp" 2>/dev/null || return 0; sleep 0.1; done
  fail "$what: the program ran on after rig ended"
}

ends "rig run" run spin.rig
rig batch build pack spin.rig >/dev/null 2>&1 || fail "rig batch build"
ends "rig batch run" batch run pack 0
