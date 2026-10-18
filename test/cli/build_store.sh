# RIG_BUILD_STORE: run, build, and test build each package in an entry
# of the store named by a hash of everything the build reads, so the same
# package from any directory shares one entry and one build, and a
# different package, or the same one built another way, never does.
# Which entry a build takes, and what rig writes in it, is rig's work
# before Zig starts, so the builds another way run a stand-in Zig
# (`zigstub`), which reports the package it is handed; the first build,
# the same package from another directory, a changed store, runs at
# once, and a linked store run Zig.
source "$ROOT/test/cli/_lib.sh"

# The stand-in Zig: `run` creates the file RIG_PROGRAM_STARTED names, as
# a program rig builds does when it starts, and prints the directory of
# the root it was handed; `build-exe` writes an executable that does.
cat >zigstub <<'EOF'
#!/bin/sh
verb=$1
root="" out=""
for a in "$@"; do
    case $a in
        -femit-bin=*) out=${a#-femit-bin=} ;;
        *.zig) root=$a ;;
    esac
done
[ -f "$root" ] || { echo "zigstub: no root $root" >&2; exit 1; }
case $verb in
    run) : >"$RIG_PROGRAM_STARTED" && dirname "$root" ;;
    build-exe) printf '#!/bin/sh\necho %s\n' "$(dirname "$root")" >"$out" && chmod +x "$out" ;;
    *) echo "zigstub: no $verb" >&2; exit 1 ;;
esac
EOF
chmod +x zigstub
stub=$PWD/zigstub

store=$PWD/store
entries() { find "$store" -mindepth 1 -maxdepth 1 -type d ! -name '.*' | wc -l | tr -d ' '; }
for p in one two three; do
  mkdir $p
  printf 'use util\n\nsub main()\n  print(util.who())\n' >$p/main.rig
done
printf 'pub fun who() -> Int\n  1\n' >one/util.rig
printf 'pub fun who() -> Int\n  1\n' >two/util.rig
printf 'pub fun who() -> Int\n  3\n' >three/util.rig

out=$(cd one && RIG_BUILD_STORE=$store "$RIG" run main.rig 2>&1); expect_eq "$out" "1" "first program"
expect_eq "$(entries)" 1 "entries after one build"
entry=$(find "$store" -mindepth 1 -maxdepth 1 -type d ! -name '.*')
[[ -f "$entry/used" ]] || fail "the entry records no use"
[[ -f "$entry/package/__rig_main.zig" && -f "$entry/package/util.zig" && -f "$entry/package/rig/runtime.zig" ]] ||
  fail "the entry lacks the package: $(cd "$entry" && find package)"
(cd one && RIG_OUT_DIR=emitted "$RIG" emit main.rig >/dev/null 2>&1) || fail "emit"
# What emit writes, but for the root's declaration of the file a program
# `rig run` builds creates as it starts.
diff -r -x __rig_main.zig one/emitted "$entry/package" >/dev/null || fail "the entry's package differs from what emit writes"
root=$(<"$entry/package/__rig_main.zig")
expect_eq "${root%%$'\n\npub const __rig_run_started = '*}" "$(<one/emitted/__rig_main.zig)" "the entry's root module"

# The same package from another directory, with a store path relative to
# it, is the same entry, and its build is Zig's cache hit.
touch -t 200001010000 "$entry/used"
out=$(cd two && RIG_BUILD_STORE=../store "$RIG" run main.rig 2>&1); expect_eq "$out" "1" "same package elsewhere"
expect_eq "$(entries)" 1 "entries after the same package from another directory"
[[ -n $(find "$entry/used" -newer one/main.rig) ]] || fail "a use does not touch the entry's \`used\`"

# Another package, or the same one built another way, has its own entry,
# which holds that package. With the stand-in Zig, whose path is part of
# what the entry is named by, `one` takes an entry of its own first.
# fresh <what> <out>: the run built in an entry of the store, $out, that
# no run before it here built in.
seen=""
fresh() {
    [[ $2 == "$store"/*/package ]] || fail "$1 ran outside the store: $2"
    [[ -f "${2%/package}/used" ]] || fail "$1: the entry records no use"
    grep -qxF -- "$2" <<<"$seen" && fail "$1 has no entry of its own: $2"
    seen=$seen$'\n'$2
}
out=$(cd one && ZIG=$stub RIG_BUILD_STORE=$store "$RIG" run main.rig 2>&1); fresh "one with another Zig" "$out"
expect_eq "$(entries)" 2 "entries after a build with another Zig"
out=$(cd three && ZIG=$stub RIG_BUILD_STORE=$store "$RIG" run main.rig 2>&1); fresh "a different module" "$out"
expect_eq "$(entries)" 3 "entries after a different package"
(cd three && RIG_OUT_DIR=emitted "$RIG" emit main.rig >/dev/null 2>&1) || fail "emit three"
diff -r -x __rig_main.zig three/emitted "$out" >/dev/null || fail "the different module's entry differs from what emit writes"
out=$(cd one && ZIG=$stub RIG_SANITIZE=1 RIG_BUILD_STORE=$store "$RIG" run main.rig 2>&1); fresh "sanitized" "$out"
expect_eq "$(entries)" 4 "entries after a sanitized build"
out=$(cd one && ZIG=$stub RIG_BUILD_STORE=$store "$RIG" run --release main.rig 2>&1); fresh "release" "$out"
expect_eq "$(entries)" 5 "entries after a release build"
printf 'use util\n\ntest "who"\n  print(util.who())\n' >one/t.rig
out=$(cd one && ZIG=$stub RIG_BUILD_STORE=$store "$RIG" test t.rig 2>&1); fresh "tests" "$out"
expect_eq "$(entries)" 6 "entries after rig test"
(cd one && ZIG=$stub RIG_BUILD_STORE=$store "$RIG" build -o prog main.rig >/dev/null 2>&1) || fail "build"
fresh "rig build" "$(one/prog)"
expect_eq "$(entries)" 7 "entries after rig build"

# A file changed in the store is written back before the build.
printf 'pub fn who() i64 {\n    return 99;\n}\n' >"$entry/package/util.zig"
out=$(cd one && RIG_BUILD_STORE=$store "$RIG" run main.rig 2>&1); expect_eq "$out" "1" "after the store's copy changed"

# Concurrent runs of one program share its entry without breaking each
# other's builds.
printf 'sub main()\n  print("hi", 4)\n' >hi.rig
for i in 1 2 3 4; do
  (RIG_BUILD_STORE=$store "$RIG" run hi.rig >"par$i.txt" 2>&1; echo "rc $?" >>"par$i.txt") &
done
wait
for i in 1 2 3 4; do expect_eq "$(cat "par$i.txt")" $'hi 4\nrc 0' "concurrent run $i"; done
expect_eq "$(entries)" 8 "entries after concurrent runs of one program"
# A store that is a link to a directory elsewhere works as one.
mkdir realstore && ln -s realstore linkstore
out=$(cd one && RIG_BUILD_STORE=../linkstore "$RIG" run main.rig 2>&1); expect_eq "$out" "1" "a store behind a link"
[[ -n $(find realstore -mindepth 1 -maxdepth 1 -type d ! -name '.*') ]] || fail "a linked store holds no entry"
exit 0
