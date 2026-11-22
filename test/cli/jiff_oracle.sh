# timeout: 300
# The Jiff oracle, tools/jiff-oracle (its README): built against Jiff
# 1.0.0 as Cargo.lock pins it, it answers a fixed set of cases with the
# values Jiff's own tests and examples assert, and it answers from the
# zone data Jiff bundles (2026f), never the machine's (`gen.py
# --bundle-check`). Then std.datetime's and std.time's answers to every
# generated case they answer (tools/jiff-oracle/answer.rig) must be
# Jiff's, part for part, except where Jiff answers `skip`. Jiff's answers
# are not committed: they are made here.
# Skipped where there is no Rust toolchain, and where the pinned crates
# are neither in Cargo's registry nor to be fetched (offline).
source "$ROOT/test/cli/_lib.sh"

if ! cargo --version >/dev/null 2>&1; then
    echo "cargo is not installed: skipped"
    exit 0
fi
dir=$ROOT/tools/jiff-oracle
export CARGO_TARGET_DIR=$RIG_OUT_DIR/jiff-oracle
if ! (cd "$dir" && { cargo fetch --locked --offline --quiet >/dev/null 2>&1 || cargo fetch --locked --quiet >/dev/null 2>&1; }); then
    echo "the pinned crates cannot be fetched (offline, and not in Cargo's registry): skipped"
    exit 0
fi
(cd "$dir" && cargo build --release --locked --offline --quiet) || fail "the oracle does not build"
bin=$CARGO_TARGET_DIR/release/jiff-oracle

ver=$("$bin" --version)
expect_eq "$ver" "jiff 1.0.0, TimeZoneDatabase(Bundled(available)), jiff-tzdb 2026f" "the oracle's database"

# Each case, then Jiff's answer, from where each comment says. A round
# line answers the round and then the floor; the floor beside a value
# from Jiff is the multiple at or before it.
cases=(
    # tests/tc39_262/civil/date/add.rs:58, `basic`
    "date.add 1976-11-18 43 0 0 0" "2019-11-18"
    "date.add 1976-11-18 0 3 0 0" "1977-02-18"
    "date.add 1976-11-18 0 0 0 20" "1976-12-08"
    "date.add 2019-01-31 0 1 0 0" "2019-02-28"
    "date.add 2019-11-18 -43 0 0 0" "1976-11-18"
    "date.add 2019-02-28 0 -1 0 0" "2019-01-28"
    # src/zoned.rs:6775, `zoned_add_calendar_units_dst`
    "zoned.add America/New_York 2024-01-31T07:30:00Z 0 1 0 0 PT0S" "2024-02-29T02:30:00-05:00[America/New_York]"
    "zoned.add America/New_York 2024-03-09T07:30:00Z 0 0 0 1 PT0S" "2024-03-10T03:30:00-04:00[America/New_York]"
    "zoned.add America/New_York 2024-03-09T07:30:00Z 0 0 0 1 PT1M" "2024-03-10T03:31:00-04:00[America/New_York]"
    # src/tz/ambiguous.rs:520 and 580, `earlier` and `later` (shown here
    # in the zone), with "compatible" and "reject" by their rules
    "datetime.in_zone 2024-07-15T17:30:00 America/New_York" "2024-07-15T17:30:00-04:00[America/New_York] 2024-07-15T17:30:00-04:00[America/New_York] 2024-07-15T17:30:00-04:00[America/New_York] 2024-07-15T17:30:00-04:00[America/New_York]"
    "datetime.in_zone 2024-03-10T02:30:00 America/New_York" "2024-03-10T03:30:00-04:00[America/New_York] 2024-03-10T01:30:00-05:00[America/New_York] 2024-03-10T03:30:00-04:00[America/New_York] error"
    "datetime.in_zone 2024-11-03T01:30:00 America/New_York" "2024-11-03T01:30:00-04:00[America/New_York] 2024-11-03T01:30:00-04:00[America/New_York] 2024-11-03T01:30:00-05:00[America/New_York] error"
    # src/zoned.rs:6349, `until_crosses_dst_multiple_days`: a since b in
    # days, weeks, months, years; years, months, days; the rest
    "zoned.count America/New_York 2024-11-03T06:00:00Z 2024-11-01T05:50:00Z" "2 0 0 0 0 0 2 PT10M"
    "zoned.count America/New_York 2024-11-01T05:50:00Z 2024-11-03T06:00:00Z" "-2 0 0 0 0 0 2 PT10M"
    "zoned.count America/New_York 2024-11-03T05:50:00Z 2024-11-04T06:00:00Z" "0 0 0 0 0 0 0 PT24H10M"
    "zoned.count America/New_York 2024-11-03T06:50:00Z 2024-11-04T06:00:00Z" "0 0 0 0 0 0 0 PT23H10M"
    "zoned.count America/New_York 2024-03-09T07:30:00Z 2024-03-10T07:00:00Z" "0 0 0 0 0 0 0 PT23H30M"
    "zoned.count Pacific/Apia 2011-12-30T21:00:00Z 2011-12-28T22:00:00Z" "1 0 0 0 0 0 1 PT23H"
    # src/zoned.rs:6612, `zoned_round_dst_day_length`
    "zoned.round America/New_York 2025-03-09T16:15:00Z days 1" "2025-03-09T00:00:00-05:00[America/New_York] 2025-03-09T00:00:00-05:00[America/New_York]"
    # src/civil/time.rs:1480 and 1483, and 3236, `rounding_cross_midnight`
    "time.round 15:27:29.999999999 minutes 5" "15:25:00 15:25:00"
    "time.round 15:27:30 minutes 5" "15:30:00 15:25:00"
    "time.round 23:59:59.999999999 hours 1" "00:00:00 23:00:00"
    "time.round 23:59:59.999999999 ms 1" "00:00:00 23:59:59.999"
    # src/signed_duration.rs:2836 and 52
    "duration.round PT15M46S minutes 1" "PT16M PT15M"
    "duration.parse PT2H30M" "PT2H30M"
    # src/tz/offset.rs:1967 and 1985: Monrovia's offset, rounded in text.
    # Kept over the zone's (the second answer), the rounded offset puts
    # the instant 30 seconds off: the trap of DATETIME-DESIGN §7.6.
    "zoned.parse 1968-02-01T23:15:00-00:45[Africa/Monrovia]" "1968-02-01T23:15:00-00:45[Africa/Monrovia] 1968-02-01T23:15:30-00:45[Africa/Monrovia] 1968-02-01T23:15:00-00:45[Africa/Monrovia]"
    "instant.in_zone 1968-02-01T23:59:30Z Africa/Monrovia" "1968-02-01T23:15:00-00:45[Africa/Monrovia] -00:44:30 MMT"
    # docs/design/datetime.md §6.5, measured: the second 01:30 in Denver on
    # 2026-11-01 with the minute set to 45 keeps its offset
    "zoned.with America/Denver 2026-11-01T08:30:00Z 2026-11-01T01:45:00" "2026-11-01T01:45:00-07:00[America/Denver] 2026-11-01T01:45:00-07:00[America/Denver] 2026-11-01T01:45:00-07:00[America/Denver] 2026-11-01T01:45:00-07:00[America/Denver]"
)
input=""
want=""
for ((i = 0; i < ${#cases[@]}; i += 2)); do
    input+="${cases[i]}"$'\n'
    want+="${cases[i + 1]}"$'\n'
done
got=$(printf '%s' "$input" | "$bin") || fail "the oracle stopped"
diff <(printf '%s' "$want") <(printf '%s\n' "$got") || fail "the oracle's answers differ from Jiff's tests"

# A line it cannot read stops it with status 2, naming the line.
out=$(printf 'date.add 2024-01-01 0 1 0 0\ndate.add 2024-01-01 1 -1 0 0\n' | "$bin" 2>&1)
rc=$?
expect_rc "$rc" 2 "amounts of both signs"
expect_has "$out" "line 2: amounts of both signs" "the refusal"

if ! command -v python3 >/dev/null; then
    echo "python3 is not installed: the bundle check and the comparison are skipped"
    exit 0
fi
(cd "$dir" && python3 gen.py --bundle-check "$bin") || fail "the oracle does not answer from Jiff's bundled data"

# std.datetime's and std.time's answers against Jiff's, on every case
# gen.py writes; a case std.datetime does not answer yet is `-`.
cases_dir=$RIG_OUT_DIR/jiff-cases
mkdir -p "$cases_dir"
(cd "$dir" && python3 gen.py "$cases_dir" >/dev/null) || fail "gen.py does not write the cases"
rig build --release "$ROOT/tools/jiff-oracle/answer.rig" -o "$cases_dir/answer" || fail "answer.rig does not build"
answered=0
for kind in calendar zones counts text round; do
    "$bin" < "$cases_dir/$kind.in" > "$cases_dir/$kind.jiff" || fail "the oracle stopped on $kind.in"
    "$cases_dir/answer" "$cases_dir/$kind.in" > "$cases_dir/$kind.rig" || fail "answer.rig stopped on $kind.in"
    expect_eq "$(wc -l < "$cases_dir/$kind.rig")" "$(wc -l < "$cases_dir/$kind.in")" "answers to $kind.in"
    tally=$(paste -d '\t' "$cases_dir/$kind.in" "$cases_dir/$kind.jiff" "$cases_dir/$kind.rig" | awk -f "$dir/compare.awk")
    echo "$kind: ${tally##*$'\n'}"
    [[ $tally == *"differ 0 "* ]] || fail "std.datetime differs from Jiff on $kind.in: $tally"
    read -r _ same _ <<<"${tally##*$'\n'}"
    answered=$((answered + same))
done
# Every case these phases answer: fewer means answer.rig stopped
# answering some.
(( answered >= 2186455 )) || fail "std.datetime answered $answered cases the same as Jiff, fewer than 2,186,455"
