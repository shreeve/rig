# io.copy between files and sockets: a file copied to a new one byte for
# byte, in 64 KiB blocks and a short last one, an empty file, a file
# served on a socket, and a socket read into a file; in debug
# (sanitized) and --release, and under 20 seeds. Between sockets:
# test/rig/std-io.rig.test. The standard streams: stdin read from a pipe
# a block at a time and copied whole, from tasks too; stderr in order
# with stdout; and a write that fails reported as its FileError, with
# the system's words. Whether a standard stream is a terminal, under a
# pseudo-terminal, piped, and closed; and stdout synced, to a file and
# to a pipe.
# timeout: 300
source "$ROOT/test/cli/_lib.sh"

cat >cp.rig <<'EOF2'
use std.file
use std.io
use std.net

fun serve_file(l: net.Listener) -> Int!
  c = l.accept()!
  if file.open("big.txt")! as f
    return io.copy(!f, !c)!
  0

sub copy(from: ?String, to: ?String)!
  if file.open(from)! as src
    dst = file.create(to, parents: true)!
    print(io.copy(!src, !dst)!)

sub main()!
  data = String()
  for i in 0..100000
    !data.add(i, "\n")
  file.write("big.txt", data)!
  copy("big.txt", "out/copy.txt")!
  print((file.read("out/copy.txt")! ?? String()) == data)
  file.write("empty.txt", "")!
  copy("empty.txt", "out/empty.txt")!
  print((file.read("out/empty.txt")! ?? String("none")).len)
  l = net.listen("127.0.0.1:0")!
  port = l.port()
  t = serve_file(<l)&
  c = net.connect(String("127.0.0.1:", port))!
  got = file.create("out/got.txt")!
  print(io.copy(!c, !got)!, >t!)
  print((file.read("out/got.txt")! ?? String()) == data)
EOF2

for mode in debug release; do
    flag=; [[ $mode == release ]] && flag=--release
    rm -rf out big.txt empty.txt
    out=$(RIG_SANITIZE=1 rig run $flag cp.rig 2>&1); expect_rc $? 0 "$mode cp: $out"
    want=$'588890\ntrue\n0\n0\n588890 588890\ntrue'
    expect_eq "$out" "$want" "$mode: file to file, an empty one, file to socket, socket to file"
    out=$(rig build $flag cp.rig 2>&1); expect_rc $? 0 "$mode build: $out"
    for run in $(seq 1 20); do
        rm -rf out
        out=$("$TIMEOUT_CMD" 20 ./cp 2>&1); expect_rc $? 0 "$mode run $run: $out"
        expect_eq "$out" "$want" "$mode: run $run"
        out=$(RIG_SEED=$run ./cp 2>&1); expect_rc $? 0 "$mode seed $run: $out"
        expect_eq "$out" "$want" "$mode: seed $run"
    done
done
# Standard input, read into one buffer a block at a time, then copied:
# how many bytes, their sum, and what `io.copy` gave.
cat >cat.rig <<'EOF2'
use std.io
use std.os

fun main() -> Int!
  input = io.stdin()
  if os.args().len > 1
    out = io.stdout()
    return io.copy(!input, !out)! % 2
  buf = String()
  total = 0
  sum = 0
  while true
    !buf.clear()
    n = (!input).read(!buf, 4096)!
    break if n == 0
    total += n
    for b in ?buf[..]
      sum += Int(b)
  print(total, sum)
  0
EOF2

# The same from a task, which reads on the blocking pool.
cat >tasked.rig <<'EOF2'
use std.io

fun count() -> Int!
  input = io.stdin()
  buf = String()
  total = 0
  while (!input).read(!buf, 65536)! > 0
    total += buf.len
    !buf.clear()
  total

sub main()!
  t = count()&
  print(>t!)
EOF2

# stderr between lines of stdout, each stream through its own handle
# and through print and warn.
cat >order.rig <<'EOF2'
use std.io

sub main()!
  out = io.stdout()
  err = io.stderr()
  (!out).write("1 ")!
  (!err).write("2 ")!
  print("3")
  warn("4")
  (!out).write("5")!
  (!err).write("6\n")!
  print()
EOF2

# A write larger than print's buffer, between prints: it goes after what
# the buffer holds, and before what comes next.
cat >big.rig <<'EOF2'
use std.io

sub main()!
  out = io.stdout()
  big = String()
  for _ in 0..20000
    !big.add("x")
  print("start")
  (!out).write(big)!
  (!out).write("\n")!
  print("end")
EOF2

# A write that fails: to stdin, to stdout read, to a full disk, to a
# closed pipe. Each prints its error and the system's words to stderr.
cat >fail.rig <<'EOF2'
use std.file
use std.io
use std.os

sub tell(e: ?error)
  err = io.stderr()
  match e
    f: file.FileError => (!err).write(String(e, " ", file.reason(f), "\n")) catch return
    _ => (!err).write(String(e, "\n")) catch return

sub main()
  how = os.args()[1]
  if how == "stdin"
    input = io.stdin()
    (!input).write("x") catch |e| tell(e)
  else if how == "read"
    out = io.stdout()
    buf = String()
    _ = (!out).read(!buf, 10) catch |e|
      tell(e)
      0
  else
    out = io.stdout()
    big = String()
    for i in 0..20000
      !big.add("line ", i, "\n")
    for _ in 0..10
      (!out).write(big) catch |e|
        tell(e)
        return
    (!out).flush() catch |e| tell(e)
EOF2

big=$(python3 -c "import sys; sys.stdout.buffer.write(bytes(i % 7 for i in range(300000)))" | tee piped.dat | wc -c | tr -d ' ')
for mode in debug release; do
    flag=; [[ $mode == release ]] && flag=--release
    out=$(RIG_SANITIZE=1 rig run $flag cat.rig <piped.dat 2>&1); expect_rc $? 0 "$mode cat: $out"
    expect_eq "$out" "300000 899997" "$mode: stdin read a block at a time"
    out=$(printf 'abc' | RIG_SANITIZE=1 rig run $flag cat.rig 2>&1); expect_rc $? 0 "$mode cat pipe: $out"
    expect_eq "$out" "3 294" "$mode: stdin from a pipe"
    out=$(RIG_SANITIZE=1 rig run $flag cat.rig -- copy <piped.dat 2>/dev/null | cmp - piped.dat 2>&1); expect_rc $? 0 "$mode copy: $out"
    out=$(RIG_SANITIZE=1 rig run $flag tasked.rig <piped.dat 2>&1); expect_rc $? 0 "$mode tasked: $out"
    expect_eq "$out" "300000" "$mode: stdin from a task"
    out=$(RIG_SANITIZE=1 rig run $flag order.rig 2>&1); expect_rc $? 0 "$mode order: $out"
    expect_eq "$out" $'1 2 3\n4\n56' "$mode: stdout and stderr in the order written"
    out=$(RIG_SANITIZE=1 rig run $flag big.rig 2>&1); expect_rc $? 0 "$mode big: $out"
    expect_eq "$out" "start"$'\n'"$(printf 'x%.0s' {1..20000})"$'\nend' "$mode: a write larger than print's buffer"
    out=$(RIG_SANITIZE=1 rig run $flag fail.rig -- stdin </dev/null 2>&1); expect_rc $? 0 "$mode stdin write: $out"
    expect_eq "$out" "FileError.bad_descriptor Bad file descriptor" "$mode: a write to stdin"
    out=$(RIG_SANITIZE=1 rig run $flag fail.rig -- read 2>&1 >out.txt); expect_rc $? 0 "$mode stdout read: $out"
    expect_eq "$out" "FileError.bad_descriptor Bad file descriptor" "$mode: a read of stdout"
    rig build $flag -o fail fail.rig >build.log 2>&1 || fail "$mode build fail: $(cat build.log)"
    if [[ -e /dev/full ]]; then
        out=$(./fail full 2>&1 >/dev/full); expect_rc $? 0 "$mode full: $out"
        expect_eq "$out" "FileError.no_space No space left on device" "$mode: a full disk"
    fi
    # The reader leaves after one line. Whether the program then sees the
    # failed write or ends by SIGPIPE is the runtime's choice: either way
    # it does not go on writing.
    err=$( { ./fail pipe | head -1 >/dev/null; echo "status ${PIPESTATUS[0]}" >&2; } 2>&1 )
    [[ $err == $'FileError.broken_pipe Broken pipe\nstatus 0' || $err == "status 141" ]] || fail "$mode: a closed pipe: $err"
done

# Whether stdin and stdout are terminals, and stdout synced: what
# `print` buffered goes out first, then the file is synced; a pipe
# cannot be, on either system.
cat >tty.rig <<'EOF2'
use std.io

sub main()
  print(io.stdin().is_terminal(), io.stdout().is_terminal())
  out = io.stdout()
  (!out).sync() catch |e|
    warn(e)
    return
  warn("synced")
EOF2
rig build -o tty tty.rig >build.log 2>&1 || fail "build tty: $(cat build.log)"
# A terminal can be synced on macOS, not on Linux. macOS's script echoes
# the end of its empty input, ^D and two backspaces, first.
if [[ $(uname -s) == Darwin ]]; then
    out=$("$TIMEOUT_CMD" 20 script -q /dev/null ./tty </dev/null 2>&1 | tr -d '\r\b' | sed 's/^^D//')
    want=$'true true\nsynced'
else
    out=$("$TIMEOUT_CMD" 20 script -qec ./tty /dev/null </dev/null 2>&1 | tr -d '\r')
    want=$'true true\nFileError.invalid'
fi
expect_eq "$out" "$want" "under a pseudo-terminal"
err=$(./tty </dev/null 2>&1 >out.txt); expect_rc $? 0 "tty to a file: $err"
expect_eq "$(cat out.txt)" "false false" "stdout to a file"
expect_eq "$err" "synced" "stdout to a file is synced"
out=$(printf '' | ./tty 2>&1 | cat); expect_rc $? 0 "tty piped: $out"
expect_eq "$out" $'false false\nFileError.invalid' "piped, and a pipe cannot be synced"
out=$(./tty <&- 2>/dev/null); expect_rc $? 0 "tty with stdin closed: $out"
expect_eq "$out" "false false" "a closed stdin is no terminal"
exit 0
