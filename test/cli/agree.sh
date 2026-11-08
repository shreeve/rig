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
# exact. The run fails, too, when fewer programs than `floor` are in
# λRig's scope, so an exporter that leaves every program outside cannot
# pass it; raise the floor as the scope grows. Needs Lean (`lake`, see
# formal/README.md): on macOS, where formal/ is built, a run without it
# fails; elsewhere it is skipped, and says so on stderr.
# timeout: 300
source "$ROOT/test/cli/_lib.sh"

floor=22
if ! command -v lake >/dev/null; then
    [[ $(uname) == Darwin ]] && fail "no lake on PATH: install Lean (formal/README.md)"
    echo "agree: SKIPPED: no lake on PATH; the checkers' agreement is not checked" >&2
    exit 0
fi
[[ -x $ROOT/bin/rig-oracle ]] || fail "no bin/rig-oracle"
[[ -d ${RIG_TESTS:-} ]] || fail "no \$RIG_TESTS"
log=$PWD/lrig-build.log
(cd "$ROOT/formal" && lake build lrig >"$log" 2>&1) || { cat "$log"; fail "lake build lrig"; }
lrig=$ROOT/formal/.lake/build/bin/lrig

python3 "$ROOT/test/cli/_agree.py" list "$RIG_TESTS" "$ROOT/examples" >programs.list
"$ROOT/bin/rig-oracle" --lambda --list programs.list >exported.txt || fail "rig-oracle --lambda"
"$lrig" <exported.txt >judged.txt || fail "lrig"
python3 "$ROOT/test/cli/_agree.py" compare judged.txt "$ROOT/test/oracle/agreement" "$floor" || fail "the checkers disagree (above)"
