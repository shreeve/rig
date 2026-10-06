# RIG_BUILD_STORE: run, build, and test build each package in an entry
# of the store named by a hash of everything the build reads, so the same
# package from any directory shares one entry and one build, and a
# different package, or the same one built another way, never does.
source "$ROOT/test/cli/_lib.sh"

store=$PWD/store
entries() { find "$store" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' '; }
for p in one two three; do
  mkdir $p
  printf 'use util\n\nsub main()\n  print(util.who())\n' >$p/main.rig
done
printf 'pub fun who() -> Int\n  1\n' >one/util.rig
printf 'pub fun who() -> Int\n  1\n' >two/util.rig
printf 'pub fun who() -> Int\n  3\n' >three/util.rig

out=$(cd one && RIG_BUILD_STORE=$store "$RIG" run main.rig 2>&1); expect_eq "$out" "1" "first program"
expect_eq "$(entries)" 1 "entries after one build"
entry=$(find "$store" -mindepth 1 -maxdepth 1 -type d)
[[ -f "$entry/used" ]] || fail "the entry records no use"
[[ -f "$entry/package/__rig_main.zig" && -f "$entry/package/util.zig" && -f "$entry/package/rig/runtime.zig" ]] ||
  fail "the entry lacks the package: $(cd "$entry" && find package)"
(cd one && RIG_OUT_DIR=emitted "$RIG" emit main.rig >/dev/null 2>&1) || fail "emit"
diff -r one/emitted "$entry/package" >/dev/null || fail "the entry's package differs from what emit writes"

# The same package from another directory, with a store path relative to
# it, is the same entry, and its build is Zig's cache hit.
touch -t 200001010000 "$entry/used"
out=$(cd two && RIG_BUILD_STORE=../store "$RIG" run main.rig 2>&1); expect_eq "$out" "1" "same package elsewhere"
expect_eq "$(entries)" 1 "entries after the same package from another directory"
[[ -n $(find "$entry/used" -newer one/main.rig) ]] || fail "a use does not touch the entry's \`used\`"

# Another package, or the same one built another way, has its own entry.
out=$(cd three && RIG_BUILD_STORE=$store "$RIG" run main.rig 2>&1); expect_eq "$out" "3" "different module"
expect_eq "$(entries)" 2 "entries after a different package"
out=$(cd one && RIG_SANITIZE=1 RIG_BUILD_STORE=$store "$RIG" run main.rig 2>&1); expect_eq "$out" "1" "sanitized"
expect_eq "$(entries)" 3 "entries after a sanitized build"
out=$(cd one && RIG_BUILD_STORE=$store "$RIG" run --release main.rig 2>&1); expect_eq "$out" "1" "release"
expect_eq "$(entries)" 4 "entries after a release build"
printf 'use util\n\ntest "who"\n  print(util.who())\n' >one/t.rig
out=$(cd one && RIG_BUILD_STORE=$store "$RIG" test t.rig 2>&1); expect_eq "${out%%$'\n'*}" "1" "tests"
expect_eq "$(entries)" 5 "entries after rig test"
(cd one && RIG_BUILD_STORE=$store "$RIG" build -o prog main.rig >/dev/null 2>&1) || fail "build"
expect_eq "$(one/prog)" "1" "built executable"
expect_eq "$(entries)" 6 "entries after rig build"

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
expect_eq "$(entries)" 7 "entries after concurrent runs of one program"
exit 0
