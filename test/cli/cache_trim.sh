# With no RIG_OUT_DIR, `rig run` and `rig build` write each program's
# package under the cache home, $XDG_CACHE_HOME/rig, and mark it used.
# At most once a day, a run or a build removes the package directories
# no run has used for 5 days; `rig clean` removes the whole cache home.
# A RIG_OUT_DIR belongs to its caller and is never trimmed.
# timeout: 300
source "$ROOT/test/cli/_lib.sh"

# Zig's own cache stays where it is, so the program builds warm.
zig_cache=$("${ZIG:-zig}" env | sed -n 's/^ *\.global_cache_dir = "\(.*\)",$/\1/p')
[[ -n "$zig_cache" ]] || fail "cannot find Zig's global cache"
export ZIG_GLOBAL_CACHE_DIR="$zig_cache" XDG_CACHE_HOME="$PWD/cache"
unset RIG_OUT_DIR
export RIG_BUILD_STORE=
home="$PWD/cache/rig"

cat >hello.rig <<'EOF'
sub main()
  print("hi")
EOF

# A package directory, last used `days` days ago.
package() { mkdir -p "$home/$1/.zig-cache"; touch -t "$(date -v-"$2"d +%Y%m%d%H%M 2>/dev/null || date -d "-$2 days" +%Y%m%d%H%M)" "$home/$1"; }
# The time of the last trim, `days` days ago.
trimmed() { touch -t "$(date -v-"$1"d +%Y%m%d%H%M 2>/dev/null || date -d "-$1 days" +%Y%m%d%H%M)" "$home/.trimmed"; }

package old-0123456789abcdef 9
package recent-0123456789abcdef 2
# Not a package directory: never removed.
mkdir -p "$home/notes"
touch -t 202001010000 "$home/notes"

out=$("$RIG" run hello.rig 2>&1); rc=$?
expect_rc "$rc" 0 "run: $out"
expect_eq "$out" "hi" "run's output"
[[ ! -e "$home/old-0123456789abcdef" ]] || fail "a package unused for 9 days was kept"
[[ -d "$home/recent-0123456789abcdef" ]] || fail "a package used 2 days ago was removed"
[[ -d "$home/notes" ]] || fail "a directory that is no package was removed"
[[ -f "$home/.trimmed" ]] || fail "the trim left no stamp"
mine=$(ls -d "$home"/hello-* 2>/dev/null)
[[ -d "$mine" ]] || fail "run wrote no package under the cache home"

# A trim less than a day ago: no other trim yet.
package stale-0123456789abcdef 9
out=$("$RIG" run hello.rig 2>&1); rc=$?
expect_rc "$rc" 0 "second run: $out"
[[ -d "$home/stale-0123456789abcdef" ]] || fail "a second trim ran within a day"

# A day later, a build trims, and a package it uses is marked used.
trimmed 2
touch -t 202001010000 "$mine"
out=$("$RIG" build -o hello hello.rig 2>&1); rc=$?
expect_rc "$rc" 0 "build: $out"
[[ ! -e "$home/stale-0123456789abcdef" ]] || fail "build did not trim"
[[ -d "$mine" ]] || fail "build removed the package it used"
[[ -n $(find "$mine" -maxdepth 0 -newer "$home/recent-0123456789abcdef") ]] || fail "build did not mark its package used"

# RIG_OUT_DIR is the caller's: the run neither trims the cache home nor
# touches what is in RIG_OUT_DIR.
package other-0123456789abcdef 9
trimmed 2
mkdir -p out/old-0123456789abcdef
touch -t 202001010000 out/old-0123456789abcdef
out=$(RIG_OUT_DIR="$PWD/out" "$RIG" run hello.rig 2>&1); rc=$?
expect_rc "$rc" 0 "run with RIG_OUT_DIR: $out"
[[ -d "$home/other-0123456789abcdef" ]] || fail "a run with RIG_OUT_DIR trimmed the cache home"
[[ -d out/old-0123456789abcdef ]] || fail "a run trimmed RIG_OUT_DIR"

# `rig clean` removes the cache home, and says so.
out=$("$RIG" clean 2>&1); rc=$?
expect_rc "$rc" 0 "clean: $out"
expect_has "$out" "removed $home" "clean's report"
[[ ! -e "$home" ]] || fail "clean left the cache home"
[[ -d out/old-0123456789abcdef ]] || fail "clean removed RIG_OUT_DIR's files"
out=$("$RIG" clean 2>&1); rc=$?
expect_rc "$rc" 0 "clean of no cache: $out"
expect_has "$out" "$home is already empty" "clean's report with no cache"
out=$("$RIG" clean hello.rig 2>&1); rc=$?
expect_rc "$rc" 2 "clean with a file"
expect_has "$out" "\`rig clean\` takes no file" "clean's usage error"
