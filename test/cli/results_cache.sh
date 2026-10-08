# The results cache never turns a run that would fail into a pass: a
# --delta run carries a test over only when its program, its directives,
# its package, the compiler's driver, Zig, and the harness are what they
# were when it passed. Each case below changes one of them and makes the
# run fail, so carrying the old pass over would be a false green.
#
# The runs use a small checkout of their own: test/run, src/main.zig, a
# behavior test and a corpus program, and as bin/rig a stand-in for
# another compiler: the real one, changed as the file `mode` says.
source "$ROOT/test/cli/_lib.sh"

real_zig=$(command -v "${ZIG:-zig}") || fail "no zig"
mkdir -p co/bin co/src co/test/behavior/a co/test/corpus
cp "$ROOT/test/run" co/test/run
cp "$ROOT/src/main.zig" co/src/main.zig
cat >co/test/behavior/a/prog.rig <<'EOF'
sub main()
  v = [1, 2, 3]
  print(v.len)

# expect:
# 3
EOF
cat >co/test/corpus/probe.rig <<'EOF'
sub main()
  s = "probe"
  print(s)
EOF
# The stand-in compiler. mode `runtime`: it emits a runtime with one more
# line, and its programs leak. mode `fail`: the same package as the real
# compiler, but its programs leak.
cat >co/bin/rig <<EOF
#!/bin/bash
mode=\$(cat "$PWD/mode" 2>/dev/null)
case \$1 in
    emit)
        "$RIG" "\$@"; rc=\$?
        [[ \$mode == runtime ]] && echo "// another runtime" >>"\$RIG_OUT_DIR/rig/runtime.zig"
        exit \$rc ;;
    run)
        "$RIG" "\$@"; rc=\$?
        [[ \$mode == runtime || \$mode == fail ]] && { echo "error: rig: memory leak detected: 1 allocations (8 bytes) never freed" >&2; exit 1; }
        exit \$rc ;;
esac
exec "$RIG" "\$@"
EOF
chmod +x co/bin/rig
# Zig, but `zig build` leaves the stand-in in place.
cat >zig <<EOF
#!/bin/bash
[[ \$1 == build ]] && exit 0
exec "$real_zig" "\$@"
EOF
chmod +x zig
cp zig zig2

export RIG_RESULTS_CACHE=$PWD/cache RIG_TEST_OUT=$PWD/out ZIG=$PWD/zig
: >mode
suite() { "$PWD/co/test/run" -v -j 2 "$@" behavior corpus 2>&1; }
# carried <output> <id>: the run carried the test over.
carried() { grep -qE "pass +$2 .*carried over" <<<"$1"; }

o=$(suite) || fail "first run: $o"
carried "$o" behavior/a/prog && fail "a run with an empty cache carried a test over"
[[ $(find cache -type f | wc -l) -eq 2 ]] || fail "expected 2 records, found: $(find cache -type f)"
o=$(suite --delta) || fail "delta run: $o"
carried "$o" behavior/a/prog && carried "$o" corpus/probe || fail "an unchanged test was not carried over: $o"
expect_has "$o" "2 passed (2 carried over)" "the summary of a delta run"
o=$(suite) || fail "a full run: $o"
carried "$o" behavior/a/prog && fail "a run without --delta carried a test over"

# A changed expectation.
cp co/test/behavior/a/prog.rig prog.rig
perl -pi -e 's/^# 3$/# 4/' co/test/behavior/a/prog.rig
o=$(suite --delta); expect_rc $? 1 "a delta run after the expected output changed"
expect_has "$o" "FAIL   behavior/a/prog" "a changed expectation"
# `# release` added: the test now also builds with --release.
{ echo "# release"; cat prog.rig; } >co/test/behavior/a/prog.rig
o=$(suite --delta) || fail "after # release: $o"
carried "$o" behavior/a/prog && fail "carried over a test whose directives changed"
cp prog.rig co/test/behavior/a/prog.rig

# A compiler whose runtime differs, and whose programs fail.
echo runtime >mode
o=$(suite --delta); expect_rc $? 1 "a delta run with another runtime"
expect_has "$o" "FAIL   behavior/a/prog" "another runtime, behavior"
expect_has "$o" "FAIL   corpus/probe" "another runtime, corpus"

# From here the stand-in emits the real compiler's package, and its
# programs fail. A compiler that runs a package differently has another
# driver, src/main.zig.
echo fail >mode
echo "// another driver" >>co/src/main.zig
o=$(suite --delta); expect_rc $? 1 "a delta run with another driver"
expect_has "$o" "FAIL   behavior/a/prog" "another driver"
cp "$ROOT/src/main.zig" co/src/main.zig

# Another harness: test/run judges runs differently.
echo "# another harness" >>co/test/run
o=$(suite --delta); expect_rc $? 1 "a delta run with another harness"
expect_has "$o" "FAIL   corpus/probe" "another harness"
cp "$ROOT/test/run" co/test/run

# Another Zig, or other settings of the run.
o=$(ZIG=$PWD/zig2 suite --delta); expect_rc $? 1 "a delta run with another Zig"
o=$(RIG_SANITIZE=0 suite --delta); expect_rc $? 1 "a delta run without the sanitizer"
o=$(RIG_TEST_TIMEOUT=7 suite --delta); expect_rc $? 1 "a delta run with another time limit"

# The same failing compiler with everything else unchanged is carried
# over: the cache holds the verdict of the package, which it shares.
o=$(suite --delta) || fail "the package's verdict: $o"
: >mode

# A failing run records nothing; a record unused for RIG_BUILD_STORE_DAYS
# goes with a full run's prune.
n=$(find cache -type f | wc -l)
echo runtime >mode
suite >/dev/null
[[ $(find cache -type f | wc -l) -eq $n ]] || fail "a failing run was recorded"
: >mode
find cache -type f -exec touch -t 200001010000 {} +
o=$(RIG_BUILD_STORE_DAYS=3 "$PWD/co/test/run" --prune 2>&1) || fail "prune: $o"
[[ -z $(find cache -type f) ]] || fail "kept records unused for years: $(find cache -type f)"

# test/matrix.py's keys change with the program's expected output,
# `--release`, the package, and the code that judges a run.
cat >m.rig <<'EOF'
sub main()
  print(1)
EOF
python3 - "$ROOT" "$RIG" "$PWD/co/bin/rig" "$PWD" <<'EOF' || fail "matrix keys"
import importlib.util, os, re, sys
root, real, standin, here = sys.argv[1:]
spec = importlib.util.spec_from_file_location("matrix", os.path.join(root, "test", "matrix.py"))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
m.RIG = real
os.makedirs(os.path.join(here, "tmp"))
r = m.Results(os.path.join(here, "mcache"), True, os.path.join(here, "tmp"))
p = os.path.join(here, "m.rig")
k = r.key(p, "1\n", False)
assert k and k == r.key(p, "1\n", False), "a key is not stable"
others = {"expected output": r.key(p, "2\n", False), "--release": r.key(p, "1\n", True)}
open(os.path.join(here, "mode"), "w").write("runtime")
m.RIG = standin
others["runtime"] = r.key(p, "1\n", False)
open(os.path.join(here, "mode"), "w").write("")
m.RIG = real
m.BAD = re.compile("another verdict")
others["verdict code"] = m.Results(os.path.join(here, "mcache"), True, os.path.join(here, "tmp")).key(p, "1\n", False)
for what, other in others.items():
    assert other and other != k, "the key does not change with " + what
r.record(k)
assert r.carried(k) and not r.carried(others["runtime"])
assert not m.Results(os.path.join(here, "mcache"), False, os.path.join(here, "tmp")).carried(k), "carried over without --delta"
EOF
exit 0
