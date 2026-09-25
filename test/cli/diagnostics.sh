# A diagnostic is `file:line:col: error: message` at the start of the
# node it is about (keywords and sigils included), then the source line
# with the node's span underlined on it. Sema's diagnostics come before
# the ownership checker's.
source "$ROOT/test/cli/_lib.sh"

cat >spans.rig <<'EOF'
fun pick(n: Int) -> Int
  if n > 0
    return
  n

sub main()
  f = ||
    break
  x = *(*(1))
  print(pick(1), x)
EOF
"$RIG" check spans.rig >out.txt 2>&1; expect_rc $? 1 "rig check of a rejected program"
expect_eq "$(cat out.txt)" "spans.rig:3:5: error: \`return\` needs a value of type \`Int\`
    return
    ^~~~~~
spans.rig:9:9: error: this value is already a shared handle \`*Int\`; \`*\` would nest handles. Clone it with \`+x\` for another handle
  x = *(*(1))
        ^~~~
spans.rig:8:5: error: \`break\` is not inside a loop (a closure body cannot leave a loop around it)
    break
    ^~~~~" "diagnostics at node spans"

# A parse error points at the token the parser stopped on, and says
# what the parser expected there when that is a short list.
cat >parse.rig <<'EOF'
sub main()
  x = (1 + )
EOF
"$RIG" check parse.rig >out.txt 2>&1; expect_rc $? 1 "rig check of a program that does not parse"
expect_eq "$(cat out.txt)" "parse.rig:2:12: error: unexpected \`)\`; expected an operand
  x = (1 + )
           ^" "parse error at its token"

# At most 100 errors print; the rest are counted.
{ echo "sub main()"; for ((i = 0; i < 150; i++)); do echo "  print(missing$i)"; done; } >many.rig
"$RIG" check many.rig >out.txt 2>&1; expect_rc $? 1 "rig check of a program with many errors"
expect_eq "$(grep -c ': error: ' out.txt)" "100" "errors printed"
expect_eq "$(tail -1 out.txt)" "50 more errors not shown" "errors counted"

# A column counts characters, not bytes.
printf 'sub main()\n  print("\xc3\xa9\xc3\xa9", missing)\n' >utf8.rig
"$RIG" check utf8.rig >out.txt 2>&1; expect_rc $? 1 "rig check of a program with UTF-8"
expect_eq "$(cat out.txt)" "utf8.rig:2:15: error: use of unbound name \`missing\`
  print(\"éé\", missing)
              ^~~~~~~" "UTF-8 column and caret"

# A name whose type did not resolve is reported once: calling it adds
# nothing.
printf 'extern f: Nope\n\nsub main()\n  raw\n    f(1)\n' >poison.rig
"$RIG" check poison.rig >out.txt 2>&1; expect_rc $? 1 "rig check of a call to a poisoned name"
expect_eq "$(grep ': error: ' out.txt)" "poison.rig:1:11: error: use of unbound type \`Nope\`" "one error"
