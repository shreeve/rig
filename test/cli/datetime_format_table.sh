# std.datetime's `format` checks its string as Rig compiles, and
# `try_format` the same string as the program runs (docs/design/datetime.md
# §8.4): the table of which directive suits which type is held twice, in
# the compiler (`sema.formatFault`) and in std (`formatted`). On each of
# the four types, every directive a format string can start (`%` and
# each printable byte, with and without the flag `-`, the precisions, the
# colon forms, and the ends) is given both ways, and the compiler must
# refuse exactly those std refuses.
source "$ROOT/test/cli/_lib.sh"

pats=()
for code in $(seq 33 126); do
    c=$(printf "\\$(printf '%03o' "$code")")
    pats+=("%$c" "%-$c")
done
pats+=("%.f" "%.0f" "%.1f" "%.5f" "%.9f" "%.10f" "%.3x" "%-.3f" "%:z" "%::z" "%:Z" "%:" "%." "%" "%-" "%05d" "%3f" "%-3d" "a%Yb" "%%Y")

# A pattern as a single-quoted Rig literal.
q="'"
lit() { printf "'%s'" "${1//$q/$q$q}"; }

types=(Date Time DateTime ZonedDateTime)
values=("datetime.Date.new(2026, 3, 8)" "datetime.Time.new(8, 7, 3)" "datetime.DateTime.new(2026, 3, 8, hour: 8, minute: 7, second: 3)" "datetime.Instant.from_unix_s(1_700_000_000).in_zone(datetime.TimeZone.utc())")

# The compiler shows at most 100 errors, so the patterns are checked in
# files of 80.
chunk=80
for k in 0 1 2 3; do
    ty=${types[k]}
    refused=""
    for ((start = 0; start < ${#pats[@]}; start += chunk)); do
        {
            echo "use std.datetime"
            echo
            echo "sub main()"
            echo "  x = ${values[k]}"
            for p in "${pats[@]:start:chunk}"; do echo "  _ = x.format($(lit "$p"))"; done
        } >"check_${ty}_$start.rig"
        out=$("$RIG" check "check_${ty}_$start.rig" 2>&1)
        [[ $out != *"not shown"* ]] || fail "$ty: errors not shown"
        # The patterns the compiler refuses, by their lines: the first
        # statement is line 5.
        for line in $(grep -oE "^check_${ty}_$start\.rig:[0-9]+:" <<<"$out" | cut -d: -f2 | sort -un); do
            (( line >= 5 )) || fail "$ty: an error before the patterns: $out"
            refused+=" $((start + line - 5)) "
        done
    done
    {
        echo "use std.datetime"
        echo
        echo "fun took(x: ?datetime.$ty, p: ?String) -> ?String"
        echo "  _ = x.try_format(p) catch return \"no\""
        echo "  \"ok\""
        echo
        echo "sub main()"
        echo "  x = ${values[k]}"
        for p in "${pats[@]}"; do echo "  print(took(x, $(lit "$p")))"; done
    } >"run_$ty.rig"
    ran=$(rig run "run_$ty.rig" 2>&1) || fail "try_format on a $ty: $ran"
    n=0
    accepted=0
    while IFS= read -r answer; do
        p=${pats[n]}
        if [[ $refused == *" $n "* ]]; then compiled=no; else compiled=ok; fi
        [[ $compiled == "$answer" ]] || fail "$ty: $(lit "$p"): format compiles $compiled, try_format gives $answer"
        [[ $answer == ok ]] && accepted=$((accepted + 1))
        n=$((n + 1))
    done <<<"$ran"
    expect_eq "$n" "${#pats[@]}" "answers of try_format on a $ty"
    echo "$ty: ${#pats[@]} patterns, $accepted taken both ways, the rest refused both ways"
done
