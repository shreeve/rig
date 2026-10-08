# The results cache never turns a run that would fail into a pass: a
# --delta run carries a test over only when its program, its directives,
# its package, the compiler's driver, Zig, the harness, and the settings
# are what they were when it passed, and a run records nothing that
# changed while it ran. Each case below changes one of them and makes
# the run fail, so carrying the old pass over would be a false green.
#
# The runs use a small checkout of their own: test/run, src/main.zig,
# behavior tests and a corpus program, and as bin/rig a stand-in for
# another compiler: the real one, changed as the words in the file `mode`
# say.
source "$ROOT/test/cli/_lib.sh"
expect_eq "${RIG_RESULTS_CACHE-unset}" "" "_lib.sh keeps tests off the shared results cache"

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
cp "$ROOT/test/behavior/effects/extern_fun_call.rig" co/test/behavior/a/libc.rig
cat >co/test/corpus/probe.rig <<'EOF'
sub main()
  s = "probe"
  print(s)
EOF
# The stand-in compiler. Its modes:
#   runtime    it emits a runtime with one more line, and its programs leak
#   fail       the same package as the real compiler, but its programs leak
#   nolibc     its emit does not say that Zig links libc
#   swap       before a run, it saves good.rig over the program
#   rebuild    during a run, bin/rig is replaced, as `zig build` does
#   harness    during a run, test/run changes
#   unguarded  its programs run past the sanitizer's mapping limit
cat >co/bin/rig <<EOF
#!/bin/bash
mode=" \$(cat "$PWD/mode" 2>/dev/null) "
has() { [[ \$mode == *" \$1 "* ]]; }
case \$1 in
    emit)
        err=\$(mktemp)
        "$RIG" "\$@" 2>"\$err"; rc=\$?
        if has nolibc; then grep -v -- '(-lc)\$' "\$err" >&2; else cat "\$err" >&2; fi
        rm -f "\$err"
        has runtime && echo "// another runtime" >>"\$RIG_OUT_DIR/rig/runtime.zig"
        exit \$rc ;;
    run)
        has swap && cp "$PWD/good.rig" "\${@: -1}"
        has rebuild && cp "\$0" "\$0.new" && mv "\$0.new" "\$0"
        has harness && echo "# changed during the run" >>"$PWD/co/test/run"
        "$RIG" "\$@"; rc=\$?
        has unguarded && echo "rig: sanitizer: mapping limit reached; further allocations are not guarded" >&2
        { has runtime || has fail; } && { echo "error: rig: memory leak detected: 1 allocations (8 bytes) never freed" >&2; exit 1; }
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
suite() { "$PWD/co/test/run" -v -j 2 "$@" behavior/a corpus 2>&1; }
# run_only [option...] <filter...>: test/run with only the filters given.
run_only() { "$PWD/co/test/run" -v -j 2 "$@" 2>&1; }
records() { find cache -type f | wc -l | tr -d ' '; }
# carried <output> <id>: the run carried the test over.
carried() { grep -qE "pass +$2 .*carried over" <<<"$1"; }

o=$(suite) || fail "first run: $o"
carried "$o" behavior/a/prog && fail "a run with an empty cache carried a test over"
[[ $(records) -eq 3 ]] || fail "expected 3 records, found: $(find cache -type f)"
o=$(suite --delta) || fail "delta run: $o"
carried "$o" behavior/a/prog && carried "$o" corpus/probe || fail "an unchanged test was not carried over: $o"
expect_has "$o" "3 passed (3 carried over)" "the summary of a delta run"
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

# Another Zig, or other settings of the run: any RIG_ variable that
# names no place, such as a runtime knob or one a program reads.
o=$(ZIG=$PWD/zig2 suite --delta); expect_rc $? 1 "a delta run with another Zig"
o=$(RIG_SANITIZE=0 suite --delta); expect_rc $? 1 "a delta run without the sanitizer"
o=$(RIG_TEST_TIMEOUT=7 suite --delta); expect_rc $? 1 "a delta run with another time limit"
o=$(RIG_SANITIZE_BLOCKS=100000 suite --delta); expect_rc $? 1 "a delta run with a sanitizer knob"
o=$(RIG_PROGRAM_READS_THIS=1 suite --delta); expect_rc $? 1 "a delta run with another RIG_ variable"

# The same package, which Zig links without libc: the key says whether it
# links libc, which is in no file of the package.
echo "fail nolibc" >mode
o=$(suite --delta); expect_rc $? 1 "a delta run where Zig links no libc"
expect_has "$o" "FAIL   behavior/a/libc" "a package linked without libc"
carried "$o" behavior/a/prog || fail "a program that does not link libc was not carried over: $o"

# The same failing compiler with everything else unchanged is carried
# over: the cache holds the verdict of the package, which it shares.
echo fail >mode
o=$(suite --delta) || fail "the package's verdict: $o"

# A failing run records nothing.
n=$(records)
echo runtime >mode
suite >/dev/null
[[ $(records) -eq $n ]] || fail "a failing run was recorded"

# A run records nothing that changed while it ran: the program (saved
# over, then saved back), bin/rig (rebuilt), or test/run, nor a run the
# sanitizer stopped guarding.
mkdir -p co/test/behavior/b
printf 'sub main()\n  print(1 + 1)\n\n# expect:\n# 3\n' >bad.rig
printf 'sub main()\n  print(1 + 2)\n\n# expect:\n# 3\n' >good.rig
cp bad.rig co/test/behavior/b/edit.rig
: >mode
o=$(run_only behavior/b); expect_rc $? 1 "the program that fails"
echo swap >mode
o=$(run_only behavior/b) || fail "the program saved over: $o"
: >mode
cp bad.rig co/test/behavior/b/edit.rig
o=$(run_only --delta behavior/b); expect_rc $? 1 "a delta run after an edit saved during a run, then undone"
expect_has "$o" "FAIL   behavior/b/edit" "an edit saved during a run"
cp good.rig co/test/behavior/b/edit.rig
n=$(records)
for m in rebuild harness unguarded; do
    echo $m >mode
    o=$(run_only behavior/b) || fail "$m: $o"
    [[ $(records) -eq $n ]] || fail "recorded a run during which: $m"
    cp "$ROOT/test/run" co/test/run
done
: >mode
o=$(run_only behavior/b) || fail "behavior/b: $o"
[[ $(records) -eq $((n + 1)) ]] || fail "a run with nothing changed was not recorded"
rm -r co/test/behavior/b

# A doc example and a behavior test of the same bytes, whose `# timeout:`
# raises only the behavior test's limit, are held to different limits.
mkdir -p co/test/behavior/c
printf '```rig\nsub main()\n  print(3)\n\n# timeout: 60\n```\n\n```output\n3\n```\n' >co/README.md
printf 'sub main()\n  print(3)\n\n# timeout: 60\n\n# expect:\n# 3\n' >co/test/behavior/c/same.rig
o=$(RIG_TEST_TIMEOUT=30 run_only behavior/c) || fail "behavior/c: $o"
o=$(RIG_TEST_TIMEOUT=30 run_only --delta doc behavior/c) || fail "doc: $o"
carried "$o" behavior/c/same || fail "behavior/c/same was not carried over: $o"
carried "$o" doc/README/L1 && fail "a doc example was carried over under another test's time limit"
rm -r co/test/behavior/c co/README.md

# A record unused for RIG_BUILD_STORE_DAYS goes with a full run's prune.
find cache -type f -exec touch -t 200001010000 {} +
o=$(RIG_BUILD_STORE_DAYS=3 "$PWD/co/test/run" --prune 2>&1) || fail "prune: $o"
[[ -z $(find cache -type f) ]] || fail "kept records unused for years: $(find cache -type f)"

# test/matrix.py's keys change with the program's expected output,
# `--release`, the package, whether Zig links libc, the code that judges
# a run, and the RIG_ settings; it records nothing that changed while the
# program ran, nor a run the sanitizer stopped guarding.
cat >m.rig <<'EOF'
sub main()
  print(1)
EOF
cp "$ROOT/test/behavior/effects/extern_fun_call.rig" libc.rig
cp "$RIG" rigcopy
python3 - "$ROOT" "$RIG" "$PWD/co/bin/rig" "$PWD" <<'EOF' || fail "matrix keys"
import importlib.util, os, re, sys
root, real, standin, here = sys.argv[1:]
spec = importlib.util.spec_from_file_location("matrix", os.path.join(root, "test", "matrix.py"))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
m.RIG = real
cache, tmp = os.path.join(here, "mcache"), os.path.join(here, "tmp")
os.makedirs(tmp)
mode = lambda words: open(os.path.join(here, "mode"), "w").write(words)
r = m.Results(cache, True, tmp)
p = os.path.join(here, "m.rig")
k = r.key(p, "1\n", False)
assert k and k == r.key(p, "1\n", False), "a key is not stable"
others = {"expected output": r.key(p, "2\n", False), "--release": r.key(p, "1\n", True)}
m.RIG = standin
mode("runtime")
others["runtime"] = r.key(p, "1\n", False)
lc = os.path.join(here, "libc.rig")
mode("nolibc")
nolibc = r.key(lc, None, False)
mode("")
m.RIG = real
assert nolibc and nolibc != r.key(lc, None, False), "the key does not change with libc"
os.environ["RIG_SANITIZE_BLOCKS"] = "100000"
others["RIG_ settings"] = m.Results(cache, True, tmp).key(p, "1\n", False)
del os.environ["RIG_SANITIZE_BLOCKS"]
bad = m.BAD
m.BAD = re.compile("another verdict")
others["verdict code"] = m.Results(cache, True, tmp).key(p, "1\n", False)
m.BAD = bad
for what, other in others.items():
    assert other and other != k, "the key does not change with " + what
r.record(k, p, "1\n", False)
assert r.carried(k) and not r.carried(others["runtime"])
assert not m.Results(cache, False, tmp).carried(k), "carried over without --delta"
# bin/rig rebuilt after the run started.
m.RIG = os.path.join(here, "rigcopy")
r2 = m.Results(os.path.join(here, "mcache2"), True, tmp)
k2 = r2.key(p, "1\n", False)
os.rename(m.RIG, m.RIG + ".old")
open(m.RIG, "wb").write(open(m.RIG + ".old", "rb").read())
os.chmod(m.RIG, 0o755)
r2.record(k2, p, "1\n", False)
assert not r2.carried(k2), "recorded a run during which bin/rig was rebuilt"
# The program saved over while it ran.
m.RIG = real
r3 = m.Results(os.path.join(here, "mcache3"), True, tmp)
k3 = r3.key(p, "1\n", False)
src = open(p).read()
open(p, "w").write(src.replace("print(1)", "print(2)"))
r3.record(k3, p, "1\n", False)
open(p, "w").write(src)
assert not r3.carried(k3), "recorded a run whose program changed while it ran"
# A run past the sanitizer's mapping limit passes, unrecorded.
m.RESULTS = r3
m.run_built = lambda path, keep, started, expect, flags, unguarded: unguarded.append(flags)
assert m.run_one(p, False, tmp, "1\n", False) == ("ok", "")
assert not r3.carried(k3), "recorded an unguarded run"
r3.record(k3, p, "1\n", False)
assert r3.carried(k3), "the key of an unchanged run was not recorded"
EOF
exit 0
