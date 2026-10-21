# `rig batch build` writes a file that several of its programs' packages
# hold (a module of the standard library) once, so Zig compiles it once;
# each program still runs as its own. With RIG_BUILD_STORE it builds in
# the store's entry for what it compiles, and `DIR/bin` links to the
# entry's executable: the same batch built again, from another
# directory, runs no Zig, and a batch whose programs changed builds
# again, with no older batch's executable left to run. Without a store
# it builds in DIR, as before.
# timeout: 300
source "$ROOT/test/cli/_lib.sh"

here=$PWD

# A Zig that counts its builds.
real=$(command -v "${ZIG:-zig}") || fail "no Zig"
printf '#!/bin/sh\n[ "$1" = build-exe ] && echo build >>"%s/builds"\nexec "%s" "$@"\n' "$PWD" "$real" >zigc
printf '#!/bin/sh\necho "zig: boom" >&2\nexit 1\n' >failzig
chmod +x zigc failzig
builds() { [[ -f $here/builds ]] && wc -l <"$here/builds" | tr -d ' ' || echo 0; }

for p in one two; do
  printf 'use std.text\n\nsub main()\n  print(text.trim("  %s  "))\n' "$p" >"$p.rig"
done
store=$PWD/store
batch() { local d=$1; shift; RIG_SANITIZE=1 ZIG=$here/zigc RIG_BUILD_STORE=$store "$RIG" batch build "$d" "$@"; }

out=$(batch a one.rig two.rig 2>&1); expect_rc $? 0 "a batch in the store: $out"
expect_eq "$(builds)" 1 "Zig builds of the first batch"
expect_eq "$("$RIG" batch run a 0)" "one" "program 0"
expect_eq "$("$RIG" batch run a 1)" "two" "program 1"
[[ -L a/bin ]] || fail "a/bin is not a link to the store's executable"
expect_eq "$(find "$store" -name __rig_std_text.zig | wc -l | tr -d ' ')" 1 "copies of std.text's Zig in the batch"
expect_eq "$(find "$store" -name __rig_main.zig | wc -l | tr -d ' ')" 2 "the programs' own root modules"

# The same batch from elsewhere: no Zig, the same executable.
mkdir elsewhere
out=$(cd elsewhere && batch b ../one.rig ../two.rig 2>&1); expect_rc $? 0 "the same batch elsewhere: $out"
expect_eq "$(builds)" 1 "Zig builds after the same batch again"
expect_eq "$(readlink elsewhere/b/bin)" "$(readlink a/bin)" "the executable the same batch links to"
expect_eq "$("$RIG" batch run elsewhere/b 1)" "two" "program 1 of the same batch"

# A changed program builds again; the first batch still runs its own.
printf 'use std.text\n\nsub main()\n  print(text.trim("  three  "))\n' >two.rig
out=$(batch a one.rig two.rig 2>&1); expect_rc $? 0 "a changed batch: $out"
expect_eq "$(builds)" 2 "Zig builds after a program changed"
[[ "$(readlink a/bin)" != "$(readlink elsewhere/b/bin)" ]] || fail "a changed batch links to the old executable"
expect_eq "$("$RIG" batch run a 1)" "three" "the changed program"
expect_eq "$("$RIG" batch run elsewhere/b 1)" "two" "the first batch, after another changed"

# A build that fails leaves no executable behind.
printf 'sub main()\n  print("four")\n' >four.rig
out=$(RIG_BUILD_STORE=$store ZIG=$PWD/failzig "$RIG" batch build a four.rig 2>&1); expect_rc $? 1 "a batch Zig fails"
[[ -e a/bin || -L a/bin ]] && fail "a failed batch left an executable"

# Without a store the batch builds in its directory, its shared files
# there too.
out=$(RIG_SANITIZE=1 RIG_BUILD_STORE= "$RIG" batch build c one.rig two.rig 2>&1); expect_rc $? 0 "a batch without a store: $out"
[[ -f c/bin && ! -L c/bin ]] || fail "without a store, c/bin is not the executable"
expect_eq "$(find c -name __rig_std_text.zig | wc -l | tr -d ' ')" 1 "copies of std.text's Zig without a store"
expect_eq "$("$RIG" batch run c 1)" "three" "program 1 without a store"
exit 0
