# The comparison of std.datetime's answers with Jiff's (README.md):
# read as `paste -d '\t' CASES JIFF RIG`. A Rig answer of `-` is a case
# not answered yet, and a Jiff answer of `skip`, or a part of one, is
# where Rig differs on purpose; any other part must be the same. Prints
# each difference, at most 20, then `same N differ N skip N open N`.
BEGIN { FS = "\t" }
{
    if ($3 == "-") { open++; next }
    if ($2 == "skip") { skip++; next }
    nj = split($2, j, " ")
    nr = split($3, r, " ")
    bad = nj != nr
    for (k = 1; k <= nj && !bad; k++)
        if (j[k] != "skip" && j[k] != r[k]) bad = 1
    if (bad) {
        differ++
        if (differ <= 20) print "differs: " $1 " | jiff: " $2 " | rig: " $3
    } else same++
}
END { printf "same %d differ %d skip %d open %d\n", same, differ, skip, open }
