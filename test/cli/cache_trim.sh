# With no RIG_OUT_DIR, `rig run`, `build`, and `test` write each
# program's package under the cache home, $XDG_CACHE_HOME/rig, holding a
# shared lock on the package while they use it. At most once a day, one
# removes the packages no run has used for 5 days; `rig clean` removes
# every package. Both act only on a home rig made (it holds rig's
# CACHEDIR.TAG, and is no link), remove only what rig makes there, and
# skip a package whose lock is held, however its run ended. A relative
# XDG_CACHE_HOME or HOME is ignored, and a RIG_OUT_DIR is never trimmed.
# Every cache here is in this test's own directory.
# timeout: 600
source "$ROOT/test/cli/_lib.sh"

# Zig's own cache stays where it is, so programs build warm.
zig_cache=$("${ZIG:-zig}" env | sed -n 's/^ *\.global_cache_dir = "\(.*\)",$/\1/p')
[[ -n "$zig_cache" ]] || fail "cannot find Zig's global cache"
export ZIG_GLOBAL_CACHE_DIR="$zig_cache" HOME="$PWD/home" XDG_CACHE_HOME="$PWD/cache"
unset RIG_OUT_DIR
export RIG_BUILD_STORE=
mkdir -p "$HOME"
home="$PWD/cache/rig"
signature="Signature: 8a477f597d28d172789f06886806bc55"

cat >hello.rig <<'EOF'
sub main()
  print("hi")
EOF
cat >sleeper.rig <<'EOF'
use std.time

sub main()
  time.sleep(60000000000)
EOF

# A time `days` days ago (a negative count is in the future).
ago() {
    local sign=- n=$1
    [[ $n == -* ]] && sign=+ n=${n#-}
    date -v"$sign$n"d +%Y%m%d%H%M 2>/dev/null || date -d "$sign$n days" +%Y%m%d%H%M
}
# A package directory as rig makes one, last used `days` days ago.
package() { mkdir -p "$home/$1/rig"; touch "$home/$1/rig/runtime.zig"; touch -t "$(ago "$2")" "$home/$1"; }
# The time of the last trim.
trimmed() { touch -t "$(ago "$1")" "$home/.trimmed"; }
# Hold a shared lock on a package's lock file, as a run does, in the
# background; `$holder` is its pid.
hold() {
    : >>"$home/$1/.lock"
    perl -e 'use Fcntl ":flock"; open(F, "<", $ARGV[0]) or die; flock(F, LOCK_SH) or die; print "held\n"; $| = 1; sleep 120' "$home/$1/.lock" >held.txt &
    holder=$!
    until grep -q held held.txt 2>/dev/null; do sleep 0.1; done
}

# An existing home is tagged only on proof that rig made it, a package
# or rig's stamp: not when it is empty, nor when it holds only entries
# named like rig's trash, which the trim would then delete.
mkdir -p "$home/.trash-0123456789abcdef"
echo mine >"$home/.trash-0123456789abcdef/notes.txt"
out=$("$RIG" run hello.rig 2>&1); rc=$?
expect_rc "$rc" 0 "run in a home of trash: $out"
[[ ! -e "$home/CACHEDIR.TAG" ]] || fail "rig tagged a home holding only trash-named entries"
[[ -f "$home/.trash-0123456789abcdef/notes.txt" ]] || fail "rig removed a trash-named directory it did not make"
rm -rf "$home" && mkdir -p "$home"
out=$("$RIG" run hello.rig 2>&1); rc=$?
expect_rc "$rc" 0 "run in an empty home: $out"
[[ ! -e "$home/CACHEDIR.TAG" ]] || fail "rig tagged an empty home"
rm -rf "$home"

# A home with something rig did not make, and no tag: nothing in it is
# touched, and it gets no tag.
package old-0123456789abcdef 9
mkdir -p "$home/notes"
out=$("$RIG" run hello.rig 2>&1); rc=$?
expect_rc "$rc" 0 "run in an untagged home: $out"
expect_eq "$out" "hi" "run in an untagged home"
[[ -d "$home/old-0123456789abcdef" && ! -e "$home/.trimmed" ]] || fail "a trim touched an untagged home"
[[ ! -e "$home/CACHEDIR.TAG" ]] || fail "rig tagged a home holding files it did not make"
out=$("$RIG" clean 2>&1); rc=$?
expect_rc "$rc" 1 "clean of an untagged home"
expect_has "$out" "not cleaning $home: it holds no CACHEDIR.TAG from rig" "clean of an untagged home"
[[ -d "$home/old-0123456789abcdef" && -d "$home/notes" ]] || fail "clean touched an untagged home"

# A home holding only rig's own entries, from a rig that wrote no tag,
# is tagged on the next run, and trimmed.
rm -rf "$home/notes" "$home"/hello-*
out=$("$RIG" run hello.rig 2>&1); rc=$?
expect_rc "$rc" 0 "run in a home of rig's: $out"
head -1 "$home/CACHEDIR.TAG" | grep -qxF "$signature" || fail "rig did not tag a home of its own entries"
expect_has "$out" "rig: removed 1 package unused for 5 days from $home" "the trim's report"
[[ ! -e "$home/old-0123456789abcdef" ]] || fail "a package unused for 9 days was kept"

package recent-0123456789abcdef 2
# Old, and held, as by a run in progress.
package busy-0123456789abcdef 9
hold busy-0123456789abcdef
touch -t "$(ago 9)" "$home/busy-0123456789abcdef"
# Last used in the future, after a clock was set back: fresh.
package ahead-0123456789abcdef -3
# Not rig's: another name, uppercase hex, a package's name without rig's
# runtime, a `rig` that is a link, a link named like a package, a link
# named like trash, and a `.trimmed`-like file that is not empty.
mkdir -p "$home/notes" "$home/up-0123456789ABCDEF/rig" "$home/mine-0123456789abcdef" elsewhere/rig "$home/linked-0123456789abcdef"
touch "$home/up-0123456789ABCDEF/rig/runtime.zig" elsewhere/rig/runtime.zig
ln -s "$PWD/elsewhere/rig" "$home/linked-0123456789abcdef/rig"
ln -s "$PWD/elsewhere" "$home/link-0123456789abcdef"
ln -s "$PWD/elsewhere" "$home/.trash-0123456789abcdef"
touch -t "$(ago 9)" "$home/notes" "$home/up-0123456789ABCDEF" "$home/mine-0123456789abcdef" "$home/linked-0123456789abcdef"
trimmed 2
out=$("$RIG" run hello.rig 2>&1); rc=$?
expect_rc "$rc" 0 "run: $out"
expect_eq "$out" "hi" "a trim that removes nothing says nothing"
[[ -d "$home/recent-0123456789abcdef" ]] || fail "a package used 2 days ago was removed"
[[ -d "$home/busy-0123456789abcdef" ]] || fail "a package whose lock is held was removed"
[[ -d "$home/ahead-0123456789abcdef" ]] || fail "a package dated in the future was removed"
for x in notes up-0123456789ABCDEF mine-0123456789abcdef linked-0123456789abcdef; do
    [[ -d "$home/$x" ]] || fail "the trim removed $x, which rig did not make"
done
[[ -L "$home/link-0123456789abcdef" && -L "$home/.trash-0123456789abcdef" && -f elsewhere/rig/runtime.zig ]] || fail "the trim removed a link, or what it names"
mine=$(ls -d "$home"/hello-* 2>/dev/null)
[[ -d "$mine" && -f "$mine/.lock" ]] || fail "run wrote no package with a lock file"

# A `.lock` that is a link is never followed: the run goes on unlocked,
# and what the link names is untouched.
echo keep >elsewhere/target
mv "$mine/.lock" "$mine/.lock.real"
ln -s "$PWD/elsewhere/target" "$mine/.lock"
out=$("$RIG" run hello.rig 2>&1); rc=$?
expect_rc "$rc" 0 "run with a linked lock file: $out"
[[ -L "$mine/.lock" && "$(cat elsewhere/target)" == keep ]] || fail "the run followed a linked lock file"
rm "$mine/.lock" && mv "$mine/.lock.real" "$mine/.lock"

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
[[ -n $(find "$mine" -maxdepth 0 -newer "$home/recent-0123456789abcdef") ]] || fail "build did not mark its package used"
[[ -d "$home/busy-0123456789abcdef" ]] || fail "build's trim removed a package whose lock is held"

# A stamp in the future (a clock set ahead, then back) is old.
package future-0123456789abcdef 9
trimmed -30
out=$("$RIG" run hello.rig 2>&1); rc=$?
expect_rc "$rc" 0 "run after a future stamp: $out"
[[ ! -e "$home/future-0123456789abcdef" ]] || fail "a stamp in the future stopped the trim"

# A run killed with SIGKILL holds no lock: once old, its package goes.
"$RIG" run sleeper.rig >/dev/null 2>&1 &
runner=$!
sleeping=""
for _ in $(seq 600); do
    sleeping=$(ls -d "$home"/sleeper-* 2>/dev/null)
    [[ -n "$sleeping" ]] && ls "$sleeping"/.started-* >/dev/null 2>&1 && break
    sleep 0.1
done
[[ -n "$sleeping" ]] || fail "the sleeper made no package"
# The run holds its lock file open to read and write, which Linux NFS
# requires of a lock (where lsof is there to show it).
if command -v lsof >/dev/null; then
    lsof -p "$runner" 2>/dev/null | grep -E "[0-9]+u .*$sleeping/\.lock$" >/dev/null ||
        fail "the run does not hold its lock file open to read and write: $(lsof -p "$runner" 2>/dev/null | grep lock)"
fi
touch -t "$(ago 9)" "$sleeping"
trimmed 2
out=$("$RIG" run hello.rig 2>&1); rc=$?
expect_rc "$rc" 0 "run beside a running program: $out"
[[ -d "$sleeping" ]] || fail "the trim removed the package of a program still running"
pkill -9 -P "$runner" 2>/dev/null
kill -9 "$runner" 2>/dev/null
wait "$runner" 2>/dev/null
pkill -9 -f "$sleeping" 2>/dev/null
touch -t "$(ago 9)" "$sleeping"
trimmed 2
out=$("$RIG" run hello.rig 2>&1); rc=$?
expect_rc "$rc" 0 "run after a killed run: $out"
[[ ! -e "$sleeping" ]] || fail "a package whose run was killed stayed locked"

# Runs at once after an idle week: each trims the others' packages, and
# none may fail.
for n in 1 2 3 4; do
    printf 'sub main()\n  print(%d)\n' "$n" >"p$n.rig"
    "$RIG" run "p$n.rig" >/dev/null 2>&1 || fail "warming p$n"
done
for round in 1 2 3 4 5; do
    for p in "$home"/p[1-4]-*; do touch -t 202001010000 "$p"; done
    trimmed 2
    pids=()
    for n in 1 2 3 4; do
        "$RIG" run "p$n.rig" >"out$n.txt" 2>&1 &
        pids+=($!)
    done
    for n in 1 2 3 4; do
        wait "${pids[$((n - 1))]}" || fail "round $round: run p$n failed: $(cat "out$n.txt")"
        grep -qx "$n" "out$n.txt" || fail "round $round: run p$n printed: $(cat "out$n.txt")"
    done
done

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

# `rig clean` removes every package but one whose lock is held, and no
# more; the home stays while it holds files rig did not make.
echo mine >"$home/.trimmed"
out=$("$RIG" clean 2>&1); rc=$?
expect_rc "$rc" 0 "clean: $out"
expect_has "$out" "rig: removed " "clean's report"
expect_has "$out" "rig: kept 1 package a run, build, or test is using" "clean's report of a held package"
expect_has "$out" "rig: kept $home, which holds files rig did not make" "clean's report of other files"
[[ -z $(ls -d "$home"/*-*[0-9a-f] 2>/dev/null | grep -v -e busy- -e mine- -e linked- -e link- ) ]] || fail "clean left a package: $(ls "$home")"
[[ -d "$home/busy-0123456789abcdef" ]] || fail "clean removed a package whose lock is held"
[[ "$(cat "$home/.trimmed")" == mine ]] || fail "clean removed a .trimmed that is not rig's"
for x in notes up-0123456789ABCDEF mine-0123456789abcdef linked-0123456789abcdef; do
    [[ -d "$home/$x" ]] || fail "clean removed $x, which rig did not make"
done
[[ -L "$home/link-0123456789abcdef" && -L "$home/.trash-0123456789abcdef" && -f elsewhere/rig/runtime.zig ]] || fail "clean removed a link, or what it names"
[[ -d out/old-0123456789abcdef ]] || fail "clean removed RIG_OUT_DIR's files"

# With only rig's entries left, and no lock held, the home goes too.
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
rm -rf "$home/notes" "$home/up-0123456789ABCDEF" "$home/mine-0123456789abcdef" "$home/linked-0123456789abcdef" "$home/link-0123456789abcdef" "$home/.trash-0123456789abcdef" "$home/.trimmed"
out=$("$RIG" clean 2>&1); rc=$?
expect_rc "$rc" 0 "second clean: $out"
expect_has "$out" "rig: removed 1 package from $home" "second clean's report"
[[ ! -e "$home" ]] || fail "clean left the cache home: $(ls -a "$home")"
out=$("$RIG" clean 2>&1); rc=$?
expect_rc "$rc" 0 "clean of no cache: $out"
expect_has "$out" "rig: nothing to clean in $home" "clean's report with no cache"
out=$("$RIG" clean hello.rig 2>&1); rc=$?
expect_rc "$rc" 2 "clean with a file"
expect_has "$out" "\`rig clean\` takes no file" "clean's usage error"

# A cache home that is a link, even to a home rig made: the trim and
# `rig clean` both leave it alone.
mkdir -p real
"$RIG" run hello.rig >/dev/null 2>&1 || fail "making a home to link to"
mv "$home" real/rig
ln -s "$PWD/real/rig" "$home"
mkdir -p real/rig/gone-0123456789abcdef/rig
touch real/rig/gone-0123456789abcdef/rig/runtime.zig
touch -t "$(ago 9)" real/rig/gone-0123456789abcdef
touch -t "$(ago 2)" real/rig/.trimmed
out=$("$RIG" run hello.rig 2>&1); rc=$?
expect_rc "$rc" 0 "run through a linked home: $out"
[[ -d real/rig/gone-0123456789abcdef ]] || fail "the trim acted on a linked home"
out=$("$RIG" clean 2>&1); rc=$?
expect_rc "$rc" 1 "clean of a linked home"
expect_has "$out" "not cleaning $home: it is a symbolic link" "clean of a linked home"
[[ -d real/rig/gone-0123456789abcdef && -L "$home" ]] || fail "clean acted on a linked home"
rm "$home"

# A relative XDG_CACHE_HOME is ignored, as the XDG spec says: the cache
# is under $HOME, and ./rig, a source tree, stays.
mkdir -p proj/rig/src proj/rig/app-0123456789abcdef/rig
echo "my source" >proj/rig/src/main.zig
touch proj/rig/app-0123456789abcdef/rig/runtime.zig
echo "$signature" >proj/rig/CACHEDIR.TAG
out=$(cd proj && XDG_CACHE_HOME=. "$RIG" clean 2>&1); rc=$?
expect_has "$out" "$HOME/.cache/rig" "clean with a relative XDG_CACHE_HOME names the cache under HOME"
[[ -f proj/rig/src/main.zig && -d proj/rig/app-0123456789abcdef ]] || fail "clean with a relative XDG_CACHE_HOME removed ./rig"
out=$(cd proj && XDG_CACHE_HOME= HOME=. "$RIG" clean 2>&1); rc=$?
expect_rc "$rc" 1 "clean with a relative HOME"
expect_has "$out" "to an absolute path" "clean with a relative HOME"
[[ -f proj/rig/src/main.zig ]] || fail "clean with a relative HOME removed a file"

# XDG_CACHE_HOME=$HOME with a source tree at $HOME/rig, untagged: it
# stays, and a run there neither tags nor trims it.
mkdir -p "$HOME/rig/src"
echo "thesis" >"$HOME/rig/src/thesis.txt"
out=$(XDG_CACHE_HOME="$HOME" "$RIG" run hello.rig 2>&1); rc=$?
expect_rc "$rc" 0 "run with XDG_CACHE_HOME=\$HOME: $out"
[[ ! -e "$HOME/rig/CACHEDIR.TAG" ]] || fail "rig tagged a source tree at \$HOME/rig"
out=$(XDG_CACHE_HOME="$HOME" "$RIG" clean 2>&1); rc=$?
expect_rc "$rc" 1 "clean with XDG_CACHE_HOME=\$HOME"
expect_has "$out" "it holds no CACHEDIR.TAG from rig" "clean's report of a source tree"
[[ -f "$HOME/rig/src/thesis.txt" ]] || fail "clean removed a source tree at \$HOME/rig"
