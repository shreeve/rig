# `rig test` writes a test's name the way it is spelled in the source,
# with any quote inside it escaped.
source "$ROOT/test/cli/_lib.sh"

cat >main.rig <<'EOF'
test "say \"hi\"\t"
  print("hi")
EOF

out=$("$RIG" test main.rig 2>&1); expect_rc $? 0 "passing test"
expect_eq "$out" $'hi\nok    test "say \\"hi\\"\\t"\n1 passed, 0 failed' "report"
