# The Zig tests of std/grapheme.zig, the chars of std.text: forward and
# backward reading agree on random text of every grapheme class and of
# bytes that are not UTF-8, and runes read backward are those read forward.
source "$ROOT/test/cli/_lib.sh"

"${ZIG:-zig}" test --cache-dir "$RIG_OUT_DIR/zig-cache" "$ROOT/std/grapheme.zig" > "$RIG_OUT_DIR/out.txt" 2>&1 || {
    cat "$RIG_OUT_DIR/out.txt"
    fail "zig test std/grapheme.zig failed"
}
