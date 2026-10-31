# std.crypto builds for every target its shim chooses by: aarch64 Linux
# with DIT (neoverse_v1) and without it at compile time (neoverse_n1,
# cortex_a72, baseline), where the kernel is asked; x86-64 Linux; and
# macOS on both, Zig compiling the emitted package for each.
source "$ROOT/test/cli/_lib.sh"

cat >crypto.rig <<'EOF2'
use std.crypto
use std.crypto.x25519
use std.crypto.blake2s

sub main()!
  a = x25519.Secret.new()
  b = x25519.Secret.of([32 of 7])
  shared = a.share(b.public())!
  c = crypto.ChaCha.of(blake2s.hash(shared))
  buf: [40]U8 = [40 of 1]
  nonce: [12]U8 = [12 of 0]
  nob: [0]U8 = []
  tag = c.seal(!buf, nonce, nob)
  c.open(!buf, tag, nonce, nob)!
  print(buf[0])
EOF2

pkg=$RIG_OUT_DIR/crypto
rm -rf "$pkg"
RIG_OUT_DIR="$pkg" "$RIG" emit crypto.rig >/dev/null 2>err.txt || fail "rig emit: $(cat err.txt)"
for t in aarch64-linux:neoverse_n1 aarch64-linux:cortex_a72 aarch64-linux:baseline aarch64-linux:neoverse_v1 x86_64-linux:baseline aarch64-macos:apple_m1 x86_64-macos:baseline; do
    (cd "$pkg" && "${ZIG:-zig}" build-exe -O ReleaseFast -target "${t%%:*}" -mcpu="${t##*:}" -fno-emit-bin __rig_main.zig) >build.log 2>&1 \
        || fail "std.crypto for ${t%%:*} (${t##*:}): $(head -20 build.log)"
done
