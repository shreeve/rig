# The datetime makers' check is std's, held a second time in the compiler
# (`sema.makerFault`, SPEC §13), so a constant call can be judged as Rig
# compiles. This holds the two equal: for each constant-checked maker
# (`Date.new`, `Time.new`, `DateTime.new`, `Duration.from_parts`,
# `Instant.from_unix_s`, `_ms`, `_us`, `TimeZone.fixed`), every tuple of
# values at and just past each edge of each part, and the cross-part
# rules (leap years, month ends, signs, the instants' range, ±25:59), is
# made twice: as a constant call, which `rig check` accepts or refuses,
# and through arguments the compiler cannot know, which std's own check
# judges as the program runs. A tuple the two judge differently fails
# the script, and prints the tuple. Edit one copy alone and it fails.
# timeout: 120
source "$ROOT/test/cli/_lib.sh"

py="$ROOT/test/cli/_maker_agree.py"
python3 "$py" gen . || fail "could not write the programs"
rig run run.rig >std.out 2>run.err || { cat run.err; fail "the run program failed"; }
python3 "$py" judge . || exit 1
