# timeout: 900
# Every place Zig writes a frame of its own is a frame owner
# (docs/INTERNALS.md, "Frame owners"): a function or method, each instance
# of a generic one, a closure, a test block, a `drop` body, and `main`.
# Each owner's frame, with the functions the automatic rule inlines into
# it, is held to its account. A pile of calls of a 56 KB helper the rule
# would inline, in each kind of owner and in each body that belongs to
# the owner around it, must stop the rule from inlining it there, and the
# program runs sanitizer-clean.
source "$ROOT/test/cli/_lib.sh"

helper='fun w(i: Int) -> Int
  t = [7000 of 0]
  for k in 0..7000
    t[k] = k + i
  t[i % 7000]'

# pile <indent>: 300 calls of `w`, as 30 lines of 10, added to `s`.
pile() {
    local r k line
    for r in $(seq 0 29); do
        line="$1s += w(i + $((r * 10)))"
        for k in $(seq 1 9); do line+=" + w(i + $((r * 10 + k)))"; done
        echo "$line"
    done
}

# A test block is an owner: the rule's inlining there is held to 64 KiB.
{
    echo "$helper"
    echo
    echo 'test "pile"'
    echo '  i = 0'
    echo '  s = 0'
    pile '  '
    echo '  print(s)'
} >testpile.rig
out=$(rig test testpile.rig 2>&1); expect_rc $? 0 "a pile in a test block: $out"
expect_has "$out" "89700" "a pile in a test block"
expect_has "$out" "1 passed, 0 failed" "a pile in a test block"
exit 0
