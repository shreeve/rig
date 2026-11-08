# The agreement test: bin/rig's ownership checker beside λRig's
# (formal/), on every program of the corpus λRig can express: the cases
# of test/rig ($RIG_TESTS) and examples/. `rig-oracle --lambda` writes
# each such program as λRig's forms with the compiler's verdict on it
# (test/oracle/lambda.zig); `lrig` runs λRig's `check` and its machine on
# it (formal/LRig.lean). A program the compiler accepts whose λRig run
# faults fails the run, always: it may be a soundness hole in the
# compiler, or a form the exporter maps wrong. A program the two checkers
# decide differently fails unless test/oracle/agreement lists it with its
# class, and a listed one that agrees now fails too, so the list stays
# exact. Needs Lean (`lake`, see formal/README.md); skipped without it.
# timeout: 300
source "$ROOT/test/cli/_lib.sh"

command -v lake >/dev/null || { echo "agree: no lake on PATH; skipped"; exit 0; }
[[ -x $ROOT/bin/rig-oracle ]] || fail "no bin/rig-oracle"
[[ -d ${RIG_TESTS:-} ]] || fail "no \$RIG_TESTS"
log=$PWD/lrig-build.log
(cd "$ROOT/formal" && lake build lrig >"$log" 2>&1) || { cat "$log"; fail "lake build lrig"; }
lrig=$ROOT/formal/.lake/build/bin/lrig

python3 "$ROOT/test/cli/_agree.py" list "$RIG_TESTS" "$ROOT/examples" >programs.list
"$ROOT/bin/rig-oracle" --lambda --list programs.list >exported.txt || fail "rig-oracle --lambda"
"$lrig" <exported.txt >judged.txt || fail "lrig"
python3 "$ROOT/test/cli/_agree.py" compare judged.txt "$ROOT/test/oracle/agreement" || fail "the checkers disagree (above)"
