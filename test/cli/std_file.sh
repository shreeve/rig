# std.file.read: a file's exact bytes in a String sized to them, or
# `none` when it cannot be read; in debug (sanitized) and --release.
# timeout: 300
source "$ROOT/test/cli/_lib.sh"

# Each path's length and first bytes, or `none`.
cat >show.rig <<'EOF2'
use std.file
use std.os

sub show(path: ?String)
  if file.read(path) as s
    b = ?s[..]
    line = String(b.len, ":")
    i = 0
    while i < b.len and i < 8
      !line.add(" ", b[i])
      i += 1
    print(line)
  else
    print("none")

sub main()
  for path in os.args()[1..]
    show(path)
EOF2

# An 8 MB file whose bytes are `i % 251`: its length, the bytes that
# differ, and that the String is owned and grows.
cat >big.rig <<'EOF2'
use std.file

sub main()
  s = file.read("big.dat") ?? String()
  wrong = 0
  b = ?s[..]
  i = 0
  while i < b.len
    if Int(b[i]) != i % 251
      wrong += 1
    i += 1
  print(b.len, wrong)
  !s.add("!")
  print(s.len)
EOF2

# A read one past the end panics.
cat >past.rig <<'EOF2'
use std.file

sub main()
  s = file.read("text.txt") ?? String()
  b = ?s[..]
  print(b.len)
  print(b[b.len])
EOF2

printf 'hello\n' >text.txt
printf 'a\0b\xff\n' >binary.dat
: >empty.dat
mkdir adir
python3 -c "import sys; sys.stdout.buffer.write(bytes(i % 251 for i in range(8 << 20)))" >big.dat
paths=(text.txt binary.dat empty.dat missing.dat adir)
want=$'6: 104 101 108 108 111 10\n5: 97 0 98 255 10\n0:\nnone\nnone'
# An unreadable file; root reads it anyway, so it is left out then.
if [[ $(id -u) -ne 0 ]]; then
    printf 'secret\n' >locked.dat
    chmod 000 locked.dat
    paths+=(locked.dat)
    want+=$'\nnone'
fi

for mode in debug release; do
    flag=; [[ $mode == release ]] && flag=--release
    out=$(RIG_SANITIZE=1 rig run $flag show.rig -- "${paths[@]}" 2>&1); expect_rc $? 0 "$mode show: $out"
    expect_eq "$out" "$want" "$mode: bytes, empty, missing, directory, unreadable"
    # A pipe reports no size, so it is read to its end.
    out=$(printf 'piped' | RIG_SANITIZE=1 rig run $flag show.rig -- /dev/stdin 2>&1); expect_rc $? 0 "$mode pipe: $out"
    expect_eq "$out" "5: 112 105 112 101 100" "$mode: a pipe"
    out=$(RIG_SANITIZE=1 rig run $flag big.rig 2>&1); expect_rc $? 0 "$mode big: $out"
    expect_eq "$out" $'8388608 0\n8388609' "$mode: an 8 MB file"
    out=$(RIG_NO_CRASH_REPORT=1 RIG_SANITIZE=1 rig run $flag past.rig 2>&1); rc=$?
    [[ $rc -ne 0 ]] || fail "$mode: a read past the end ran on: $out"
    expect_has "$out" "index out of bounds" "$mode: a read past the end"
    expect_eq "$(head -1 <<<"$out")" "6" "$mode: past.rig's length"
done
[[ -e locked.dat ]] && chmod 600 locked.dat

# The buffer holds exactly the file: a String kept alive by a cycle of
# `*T` handles leaks, and the bytes leaked grow by exactly the bytes
# the file grows by.
cat >leak.rig <<'EOF2'
use std.file

obj Node
  text: String
  next: *Cell[*Node?]

sub main()
  a = *Node(text: file.read("leak.dat") ?? String(), next: *Cell(none))
  !a.next.set(+a)
  print(a.text.len)
EOF2
leaked() {
    head -c "$1" big.dat >leak.dat
    out=$(rig run leak.rig 2>&1); expect_rc $? 1 "a leak of $1 bytes: $out"
    expect_eq "$(head -1 <<<"$out")" "$1" "the length of $1 bytes"
    sed -n 's/.*memory leak detected: [0-9]* allocations (\([0-9]*\) bytes).*/\1/p' <<<"$out"
}
small=$(leaked 1000); large=$(leaked 3001)
[[ -n $small && -n $large ]] || fail "no leak report"
expect_eq "$((large - small))" 2001 "the buffer is sized to the file"
exit 0
