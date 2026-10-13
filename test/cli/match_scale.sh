# A `match` is checked and emitted in time linear in its arms: payload
# arms as a statement; as a value, integer arms apart, a run of them
# from a type's least value, and arms on an enum, half of them guarded.
# A program of 4000 arms each takes about four times as long as one of
# 1000, where time that grows with the square of the arms would take
# sixteen.
source "$ROOT/test/cli/_lib.sh"
export LC_ALL=C

# program <n>: four matches of <n> arms each, in m<n>.rig.
program() {
  local n=$1 i
  {
    printf 'enum E\n'
    for ((i = 0; i < n; i++)); do printf '  v%d(a: Int, b: Int)\n' $i; done
    printf '\nenum G\n'
    for ((i = 0; i < n / 2; i++)); do printf '  g%d\n' $i; done
    printf '\nfun payloads(x: ?E) -> Int\n  t = 0\n  match x\n'
    for ((i = 0; i < n; i++)); do printf '    .v%d(a, b) => t += a + b + %d\n' $i $i; done
    printf '  t\n\nfun ints(x: Int) -> Int\n  r = match x\n'
    for ((i = 0; i < n; i++)); do printf '    %d => %d\n' $((2 * (n - i))) $i; done
    printf '    _ => 0\n  r\n\nfun run(x: U16) -> Int\n  r = match x\n'
    for ((i = 0; i < n; i++)); do printf '    %d => %d\n' $i $i; done
    printf '    _ => 0\n  r\n\nfun guarded(x: ?G, k: Int) -> Int\n  r = match x\n'
    for ((i = 0; i < n / 2; i++)); do printf '    .g%d if k > %d => %d\n    .g%d => %d\n' $i $i $i $i $((i + 1)); done
    printf '  r\n\nsub main()\n  e = E.v1(a: 1, b: 2)\n  g = G.g3\n  print(payloads(?e), ints(4), run(5), guarded(?g, 0))\n'
  } >"m$n.rig"
}

# timed <n>: run `rig emit` on m<n>.rig, its time in seconds in m<n>.time.
timed() {
  local TIMEFORMAT=%R rc
  { time "$TIMEOUT_CMD" 120 "$RIG" emit "m$1.rig" >/dev/null 2>"m$1.err"; rc=$?; } 2>"m$1.time"
  [[ $rc -eq 0 ]] || fail "${1}-arm matches, exit status $rc: $(cat "m$1.err")"
}

program 1000
program 4000
timed 1000
timed 4000
small=$(<m1000.time) large=$(<m4000.time)
# Under half a second, startup and noise outweigh the arms.
awk -v s="$small" -v l="$large" 'BEGIN { exit !(l < 0.5 || l < 8 * s) }' ||
  fail "4000 arms took ${large}s, 1000 took ${small}s: more than 8 times as long"
