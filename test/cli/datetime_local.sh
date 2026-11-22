# `datetime.local()` (docs/design/datetime.md §7.7): `TZ`, when it is
# set, empty for UTC, a name, `:name`, a path cut after `zoneinfo/`, an
# absolute path with none read as a link, a rule with no daylight
# saving as a fixed zone; anything else fails with
# `DateTimeError.unknown_zone` and never falls through. With no `TZ`,
# the system's files: a zone this data has, or `no_system_zone`.
source "$ROOT/test/cli/_lib.sh"

cat >local.rig <<'EOF2'
use std.datetime

sub main()
  z = datetime.local() catch |e|
    print(e)
    return
  print(z.name())
EOF2
rig build local.rig -o local || fail "local.rig does not build"

zones=$PWD/share/zoneinfo
mkdir -p "$zones/Asia" link
: >"$zones/Asia/Tokyo"
ln -s "$zones/Asia/Tokyo" link/tokyo
ln -s ../share/zoneinfo/Pacific/Apia link/apia
ln -s "$PWD/nowhere" link/plain
# Chains of links: what each names is followed, up to eight, and then cut.
ln -s tokyo link/hop1
ln -s hop1 link/hop2
for i in 3 4 5 6 7 8 9; do ln -s "hop$((i - 1))" "link/hop$i"; done
ln -s loop2 link/loop1
ln -s loop1 link/loop2
: >plainfile

cases=(
    ""                                  "UTC"
    "America/Denver"                    "America/Denver"
    "america/denver"                    "America/Denver"
    ":America/New_York"                 "America/New_York"
    "UTC"                               "UTC"
    "utc"                               "UTC"
    "Etc/UTC"                           "Etc/UTC"
    "EST5EDT"                           "EST5EDT"
    "/usr/share/zoneinfo/Asia/Tokyo"    "Asia/Tokyo"
    ":/usr/share/zoneinfo/Europe/Paris" "Europe/Paris"
    "/var/db/timezone/zoneinfo/America/Denver" "America/Denver"
    ":$PWD/link/tokyo"                  "Asia/Tokyo"
    "$PWD/link/apia"                    "Pacific/Apia"
    ":$PWD/link/plain"                  "DateTimeError.unknown_zone"
    ":$PWD/link/hop1"                   "Asia/Tokyo"
    "$PWD/link/hop7"                    "Asia/Tokyo"
    "$PWD/link/hop8"                    "DateTimeError.unknown_zone"
    ":$PWD/link/loop1"                  "DateTimeError.unknown_zone"
    ":$PWD/plainfile"                   "DateTimeError.unknown_zone"
    ":$PWD/missing"                     "DateTimeError.unknown_zone"
    "UTC0"                              "UTC"
    "EST5"                              "-05:00"
    "<+08>-8"                           "+08:00"
    "<-0330>3:30"                       "-03:30"
    "XYZ-25:59"                         "+25:59"
    "IST-5:30"                          "+05:30"
    "EST5EDT,M3.2.0,M11.1.0"            "DateTimeError.unknown_zone"
    "EST5:00:30"                        "DateTimeError.unknown_zone"
    "XYZ-26"                            "DateTimeError.unknown_zone"
    "AB5"                               "DateTimeError.unknown_zone"
    ":UTC0"                             "DateTimeError.unknown_zone"
    ":EST5"                             "DateTimeError.unknown_zone"
    "nonsense"                          "DateTimeError.unknown_zone"
    "Mars/Base"                         "DateTimeError.unknown_zone"
    "/usr/share/zoneinfo/"              "DateTimeError.unknown_zone"
)
for ((i = 0; i < ${#cases[@]}; i += 2)); do
    got=$(TZ="${cases[i]}" ./local 2>&1)
    expect_eq "$got" "${cases[i + 1]}" "TZ=${cases[i]}"
done

# With no TZ: the system's own zone, which this data names, or no zone
# at all; never a failure of another kind.
got=$(env -u TZ ./local 2>&1)
case $got in
    DateTimeError.no_system_zone) ;;
    DateTimeError.*) fail "with no TZ: $got" ;;
    *) printf 'use std.datetime\n\nsub main()!\n  print(datetime.TimeZone.named("%s").name())\n' "$got" >check.rig
       expect_eq "$(rig run check.rig 2>&1)" "$got" "with no TZ, the system's zone $got" ;;
esac
echo "no TZ: $got"
