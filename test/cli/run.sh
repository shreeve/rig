# `rig run` in each mode; the program's exit status passes through, and
# output printed before a panic comes out before the panic message.
source "$ROOT/test/cli/_lib.sh"

cat >hi.rig <<'EOF'
sub main()
  print("hi", 1 + 2)
EOF
for flag in "" --release --release=safe --release=fast; do
  out=$("$RIG" run $flag hi.rig 2>&1); expect_rc $? 0 "run $flag"
  expect_eq "$out" "hi 3" "run $flag"
done

cat >boom.rig <<'EOF'
fun at(xs: [3]Int, i: Int) -> Int
  xs[i]

sub main()
  print("before")
  print("still before")
  print(at([1, 2, 3], 7))
  print("never")
EOF
"$RIG" run boom.rig >out.txt 2>err.txt; rc=$?
[[ $rc -ne 0 ]] || fail "a panicking program exited 0"
expect_eq "$(cat out.txt)" $'before\nstill before' "stdout of a panicking program"
expect_has "$(cat err.txt)" "index out of bounds" "panic message"

# One stream: buffered output is flushed before the panic is written.
"$RIG" run boom.rig >both.txt 2>&1
first_panic=$(grep -n "panic" both.txt | head -1 | cut -d: -f1)
last_print=$(grep -n "still before" both.txt | cut -d: -f1)
[[ -n "$first_panic" && "$last_print" -lt "$first_panic" ]] || fail "print output came after the panic: $(cat both.txt)"

# Concurrent runs of one program share its default output directory
# without breaking each other's builds.
for i in 1 2 3 4; do
  (unset RIG_OUT_DIR; XDG_CACHE_HOME=$PWD/cache "$RIG" run hi.rig >"par$i.txt" 2>&1; echo "rc $?" >>"par$i.txt") &
done
wait
for i in 1 2 3 4; do expect_eq "$(cat "par$i.txt")" $'hi 3\nrc 0' "concurrent run $i"; done
exit 0
