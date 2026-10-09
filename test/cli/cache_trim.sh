# With no RIG_OUT_DIR, `rig run` and `rig build` write each program's
# package under the cache home, $XDG_CACHE_HOME/rig, and mark it used.
# At most once a day, a run or a build removes the package directories
# no run has used for 5 days; `rig clean` removes every package. Both
# remove only what rig makes there, never a package a run is using, and
# never anything under a relative XDG_CACHE_HOME or HOME. A RIG_OUT_DIR
# belongs to its caller and is never trimmed. Every cache here is in
# this test's own directory.
# timeout: 300
source "$ROOT/test/cli/_lib.sh"

# Zig's own cache stays where it is, so the program builds warm.
zig_cache=$("${ZIG:-zig}" env | sed -n 's/^ *\.global_cache_dir = "\(.*\)",$/\1/p')
[[ -n "$zig_cache" ]] || fail "cannot find Zig's global cache"
export ZIG_GLOBAL_CACHE_DIR="$zig_cache" HOME="$PWD/home" XDG_CACHE_HOME="$PWD/cache"
unset RIG_OUT_DIR
export RIG_BUILD_STORE=
mkdir -p "$HOME"
home="$PWD/cache/rig"

cat >hello.rig <<'EOF'
sub main()
  print("hi")
EOF

# A time `days` days ago (a negative count is in the future).
ago() {
    local sign=- n=$1
    [[ $n == -* ]] && sign=+ n=${n#-}
    date -v"$sign$n"d +%Y%m%d%H%M 2>/dev/null || date -d "$sign$n days" +%Y%m%d%H%M
}
# A package directory as rig makes one, last used `days` days ago.
package() { mkdir -p "$home/$1/rig" "$home/$1/.zig-cache"; touch "$home/$1/rig/runtime.zig"; touch -t "$(ago "$2")" "$home/$1"; }
# The time of the last trim.
trimmed() { touch -t "$(ago "$1")" "$home/.trimmed"; }

package old-0123456789abcdef 9
package recent-0123456789abcdef 2
# Named like a package, old, with a run in progress in it.
package busy-0123456789abcdef 9
touch "$home/busy-0123456789abcdef/.started-00112233"
touch -t "$(ago 9)" "$home/busy-0123456789abcdef"
# Not rig's: another name, a package's name without rig's runtime, and
# a link named like a package to a directory elsewhere.
mkdir -p "$home/notes" "$home/mine-0123456789abcdef" elsewhere/rig
touch elsewhere/rig/runtime.zig
ln -s "$PWD/elsewhere" "$home/link-0123456789abcdef"
touch -t "$(ago 9)" "$home/notes" "$home/mine-0123456789abcdef"

out=$("$RIG" run hello.rig 2>&1); rc=$?
expect_rc "$rc" 0 "run: $out"
expect_has "$out" "hi" "run's output"
expect_has "$out" "rig: removed 1 package unused for 5 days from $home" "the trim's report"
[[ ! -e "$home/old-0123456789abcdef" ]] || fail "a package unused for 9 days was kept"
[[ -d "$home/recent-0123456789abcdef" ]] || fail "a package used 2 days ago was removed"
[[ -d "$home/busy-0123456789abcdef" ]] || fail "a package a run is using was removed"
[[ -d "$home/notes" && -d "$home/mine-0123456789abcdef" ]] || fail "a directory rig did not make was removed"
[[ -L "$home/link-0123456789abcdef" && -f elsewhere/rig/runtime.zig ]] || fail "a link, or what it names, was removed"
[[ -f "$home/.trimmed" ]] || fail "the trim left no stamp"
mine=$(ls -d "$home"/hello-* 2>/dev/null)
[[ -d "$mine" ]] || fail "run wrote no package under the cache home"

# A trim less than a day ago: no other trim yet.
package stale-0123456789abcdef 9
out=$("$RIG" run hello.rig 2>&1); rc=$?
expect_rc "$rc" 0 "second run: $out"
expect_eq "$out" "hi" "second run's output"
[[ -d "$home/stale-0123456789abcdef" ]] || fail "a second trim ran within a day"

# A day later, a build trims, and a package it uses is marked used.
trimmed 2
touch -t 202001010000 "$mine"
out=$("$RIG" build -o hello hello.rig 2>&1); rc=$?
expect_rc "$rc" 0 "build: $out"
[[ ! -e "$home/stale-0123456789abcdef" ]] || fail "build did not trim"
[[ -d "$mine" ]] || fail "build removed the package it used"
[[ -n $(find "$mine" -maxdepth 0 -newer "$home/recent-0123456789abcdef") ]] || fail "build did not mark its package used"

# A stamp in the future (a clock set ahead, then back) is old.
package ahead-0123456789abcdef 9
trimmed -30
out=$("$RIG" run hello.rig 2>&1); rc=$?
expect_rc "$rc" 0 "run after a future stamp: $out"
[[ ! -e "$home/ahead-0123456789abcdef" ]] || fail "a stamp in the future stopped the trim"

# RIG_OUT_DIR is the caller's: the run neither trims the cache home nor
# touches what is in RIG_OUT_DIR.
package other-0123456789abcdef 9
trimmed 2
mkdir -p out/old-0123456789abcdef/rig
touch out/old-0123456789abcdef/rig/runtime.zig
touch -t 202001010000 out/old-0123456789abcdef
out=$(RIG_OUT_DIR="$PWD/out" "$RIG" run hello.rig 2>&1); rc=$?
expect_rc "$rc" 0 "run with RIG_OUT_DIR: $out"
[[ -d "$home/other-0123456789abcdef" ]] || fail "a run with RIG_OUT_DIR trimmed the cache home"
[[ -d out/old-0123456789abcdef ]] || fail "a run trimmed RIG_OUT_DIR"

# `rig clean` removes every package but one in use, the stamp, and no
# more; the cache home stays while it holds files rig did not make.
out=$("$RIG" clean 2>&1); rc=$?
expect_rc "$rc" 0 "clean: $out"
expect_has "$out" "rig: removed 3 packages from $home" "clean's report"
expect_has "$out" "rig: kept 1 package a run is using" "clean's report of a run in progress"
expect_has "$out" "rig: kept $home, which holds files rig did not make" "clean's report of other files"
[[ ! -e "$home/recent-0123456789abcdef" && ! -e "$mine" && ! -e "$home/.trimmed" ]] || fail "clean left what rig made"
[[ -d "$home/busy-0123456789abcdef" ]] || fail "clean removed a package a run is using"
[[ -d "$home/notes" && -d "$home/mine-0123456789abcdef" && -L "$home/link-0123456789abcdef" && -f elsewhere/rig/runtime.zig ]] || fail "clean removed what rig did not make"
[[ -d out/old-0123456789abcdef ]] || fail "clean removed RIG_OUT_DIR's files"

# With only what rig made in it, the cache home goes too.
rm -rf "$home/notes" "$home/mine-0123456789abcdef" "$home/link-0123456789abcdef" "$home/busy-0123456789abcdef/.started-00112233"
out=$("$RIG" clean 2>&1); rc=$?
expect_rc "$rc" 0 "second clean: $out"
expect_has "$out" "rig: removed 1 package from $home" "second clean's report"
[[ ! -e "$home" ]] || fail "clean left an empty cache home"
out=$("$RIG" clean 2>&1); rc=$?
expect_rc "$rc" 0 "clean of no cache: $out"
expect_has "$out" "rig: nothing to clean in $home" "clean's report with no cache"
out=$("$RIG" clean hello.rig 2>&1); rc=$?
expect_rc "$rc" 2 "clean with a file"
expect_has "$out" "\`rig clean\` takes no file" "clean's usage error"

# A relative XDG_CACHE_HOME is ignored, as the XDG spec says: the cache
# is under $HOME, and ./rig, a source tree, stays.
mkdir -p proj/rig/src proj/rig/app-0123456789abcdef/rig
echo "my source" >proj/rig/src/main.zig
touch proj/rig/app-0123456789abcdef/rig/runtime.zig
out=$(cd proj && XDG_CACHE_HOME=. "$RIG" clean 2>&1); rc=$?
expect_rc "$rc" 0 "clean with a relative XDG_CACHE_HOME: $out"
expect_has "$out" "$HOME/.cache/rig" "clean with a relative XDG_CACHE_HOME names the cache under HOME"
[[ -f proj/rig/src/main.zig && -d proj/rig/app-0123456789abcdef ]] || fail "clean with a relative XDG_CACHE_HOME removed ./rig"
out=$(cd proj && XDG_CACHE_HOME= HOME=. "$RIG" clean 2>&1); rc=$?
expect_rc "$rc" 1 "clean with a relative HOME"
expect_has "$out" "to an absolute path" "clean with a relative HOME"
[[ -f proj/rig/src/main.zig ]] || fail "clean with a relative HOME removed a file"

# XDG_CACHE_HOME=$HOME with a source tree at $HOME/rig: it stays.
mkdir -p "$HOME/rig/src"
echo "thesis" >"$HOME/rig/src/thesis.txt"
out=$(XDG_CACHE_HOME="$HOME" "$RIG" clean 2>&1); rc=$?
expect_rc "$rc" 0 "clean with XDG_CACHE_HOME=\$HOME: $out"
expect_has "$out" "rig: removed 0 packages from $HOME/rig" "clean's report of a source tree"
expect_has "$out" "which holds files rig did not make" "clean's report of a source tree"
[[ -f "$HOME/rig/src/thesis.txt" ]] || fail "clean removed a source tree at \$HOME/rig"
