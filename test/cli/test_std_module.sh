# `rig test std.NAME` runs the test blocks of a module of the standard
# library in use, the embedded one or RIG_STD's, loaded as the library
# (so its `extern zig` blocks bind): a directory module's files and its
# `*_test.rig` files, which see its private names. The modules it
# imports, the library's included, have their test blocks checked and
# not run. A path is a program's file, as ever.
source "$ROOT/test/cli/_lib.sh"

cp -R "$ROOT/std" lib
# utf16 imports utf8: utf16's blocks run, utf8's are only checked.
cat >>lib/utf16.rig <<'EOF2'

test "utf16 passes"
  is_surrogate(0xD800)

test "utf16 fails"
  1 + 1 == 3
EOF2
cat >>lib/utf8.rig <<'EOF2'

test "utf8 is not run"
  false
EOF2
out=$(RIG_STD="$PWD/lib" rig test std.utf16 2>&1); expect_rc $? 1 "a failing test of std.utf16: $out"
expect_has "$out" 'ok    test "utf16 passes"' "std.utf16's passing test"
expect_has "$out" 'FAIL  test "utf16 fails": 1 + 1 == 3 is false' "std.utf16's failing test"
expect_has "$out" '1 passed, 1 failed' "std.utf16's count"
[[ $out == *'utf8 is not run'* ]] && fail "an imported module's test ran: $out"

# A directory module with a test file, which reads a private name, and
# the module's `extern zig` shim.
cat >lib/crypto/probe_test.rig <<'EOF2'
test "a private name of std.crypto"
  m = mac64_of([16 of 1])
  m.r0 != 0 and barrier(7) == 7
EOF2
out=$(RIG_STD="$PWD/lib" rig test std.crypto 2>&1); expect_rc $? 0 "rig test std.crypto: $out"
expect_has "$out" 'ok    test "a private name of std.crypto"' "a test file of std.crypto"
expect_has "$out" ' 0 failed' "std.crypto's count"
out=$(RIG_STD="$PWD/lib" rig test std.crypto.x25519 2>&1); expect_rc $? 0 "rig test std.crypto.x25519: $out"
expect_has "$out" '0 passed, 0 failed' "a module under a directory"

# The embedded library, with no RIG_STD.
out=$(rig test std.utf8 2>&1); expect_rc $? 0 "rig test std.utf8, embedded: $out"
expect_has "$out" '0 passed, 0 failed' "the embedded std.utf8"

# A name that is no module of the library, and the library alone.
out=$("$RIG" test std.nope 2>&1); expect_rc $? 1 "rig test std.nope"
expect_has "$out" "error: the standard library has no module \`nope\`" "rig test std.nope"
out=$(RIG_STD="$PWD/lib" "$RIG" test std.crypto.nope 2>&1); expect_rc $? 1 "rig test std.crypto.nope"
expect_has "$out" "error: the standard library has no module \`std.crypto.nope\`" "rig test std.crypto.nope"
out=$("$RIG" test std 2>&1); expect_rc $? 2 "rig test std"
expect_has "$out" "\`rig test std\` takes one module of the standard library: \`rig test std.NAME\`" "rig test std"
# Only `rig test` takes a module's name.
out=$("$RIG" check std.utf8 2>&1); expect_rc $? 2 "rig check std.utf8"
expect_has "$out" "\`std.utf8\` is not a .rig file" "rig check std.utf8"
