#!/bin/bash
# The opcode study on one machine, from the repository root.
#   xrun.sh test VARIANTS        the JSON tests against each patched variant
#   xrun.sh build OUT VARIANTS   build every file's variants (--dsym on macOS)
#   xrun.sh profile OUT          per-file profile of the base build
#   xrun.sh time OUT VARIANTS    interleaved timing, fastest of $REPS (15)
# On pup, through .git/revamp/r3/pup.sh: set PIN=CPU to pin the timing to
# one core. FILES overrides the six corpus files.
set -e
H=$(cd "$(dirname "$0")" && pwd)
FILES=${FILES:-twitter,twitterescaped,canada,citm_catalog,gsoc-2018,github_events}
"$H/../../../tools/fetch-json-data.sh" >/dev/null
case $1 in
  test)
    for v in ${2//,/ }; do printf '%s: ' "$v"; "$H/optest.sh" "$v" | tail -2 | tr '\n' ' '; echo; done ;;
  build)
    D=; [ "$(uname)" = Darwin ] && D=--dsym
    "$H/build.py" "$2" "$FILES" "base,$3" $D ;;
  profile)
    LINES=${LINES:-0} "$H/profile.py" "$2" "$FILES" base "${SECS:-8}" ;;
  time)
    "$H/optime.py" "$2" "$FILES" "$3" "${REPS:-15}" "${MS:-250}" ;;
  *) sed -n '2,8p' "$0"; exit 2 ;;
esac
