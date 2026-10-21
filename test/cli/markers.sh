# timeout: 120
# The function markers (SPEC.md, "Function markers"): `inline fun` is
# emitted `inline fn` at any size, `called fun` is emitted `noinline fn`,
# and a body that starts with `rarely` starts with Zig's cold hint; the
# last two are never inlined by the compiler's own rule.
# test/rig/emit-markers.rig.test
# checks the shape of the Zig of each and what the programs print, and
# tools/markers.py writes it and the programs here. This script reads
# what the command line shows: std.json's shape, one parser with two
# compile-time instances, built in --release, where the `inline` helper
# leaves no function of its own, the rarely called one keeps one, and a
# `called` parser keeps one function for each instance; a marked inline
# function's frame in `rig check --facts=frames`; the depth `rig check`
# holds marked calls to; and `rig test` of a program with markers.
source "$ROOT/test/cli/_lib.sh"

gen=$ROOT/tools/markers.py

# In the optimized program the marked `number` has no function of its
# own, inlined into both instances, and the rarely called `utf8_text`
# keeps one, which LLVM leaves alone. A `called` `doc` keeps one function
# for each of its two instances, which LLVM may otherwise inline into
# `main`. The program holds the parser three times: `_d` unmarked (its
# `number`, over the size limit, is called), `_m` marked, and `_c` marked
# and `called`.
python3 "$gen" kinds >kinds.rig || fail "write kinds.rig"
rig build --release -o prog_kinds kinds.rig >build.log 2>&1 || fail "release kinds: $(cat build.log)"
out=$(./prog_kinds 2>&1) || fail "release kinds ran: $out"
expect_eq "$out" $'583 40022273\n585 40022275\n587 40022277' "release kinds"
if command -v nm >/dev/null; then
    syms() { nm prog_kinds | grep -oE "__rig_main\.(number|utf8_text)_$1\$" | sed "s/_$1\$//" | sort -u | tr '\n' ' '; }
    expect_eq "$(syms d)" "__rig_main.number " "release unmarked: functions kept"
    expect_eq "$(syms m)" "__rig_main.utf8_text " "release marked: functions kept"
    expect_eq "$(syms c)" "__rig_main.utf8_text " "release called: functions kept"
    expect_eq "$(nm prog_kinds | grep -cE '__rig_main\.doc_c')" 2 "release called: one function for each of doc's instances"
fi

# A marked `inline` function whose frame alone would make it `noinline`
# (4 times its reach passes 1 MiB): its values land in its caller, whose
# account holds them (its marked part).
python3 "$gen" large >large.rig || fail "write large.rig"
facts=$(rig check --facts=frames large.rig 2>&1) || fail "facts large.rig: $facts"
marked=$(awk '$2 == "`near`" { print $(NF - 1) }' <<<"$facts")
[[ -n $marked && $marked -ge 320000 ]] || fail "near's account lacks huge's 320000 bytes: $facts"

# Calls of marked `inline` functions nest at most 256 deep
# (`typecheck.max_inline_depth`); the case "markers inline nest 256 deep"
# runs a chain 256 deep.
python3 "$gen" chain-257 >deep257.rig || fail "write deep257.rig"
out=$(rig check deep257.rig 2>&1) && fail "a chain of 257 marked calls is accepted"
expect_has "$out" 'calls of `inline` functions nest more than 256 deep through this one' "a chain of 257 marked calls"
python3 "$gen" chain-10000 >deep10000.rig || fail "write deep10000.rig"
out=$(rig check deep10000.rig 2>&1) && fail "a chain of 10,000 marked calls is accepted"
expect_has "$out" 'nest more than 256 deep' "a chain of 10,000 marked calls"

# `rig test` runs a program's test blocks with its marked functions.
python3 "$gen" tested >tested.rig || fail "write tested.rig"
out=$(rig test tested.rig 2>&1) || fail "rig test: $out"
expect_has "$out" "6 -4 105" "rig test"
true
