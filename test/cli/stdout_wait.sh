# What `print` buffers is written out before the program waits: a
# server's first line reaches a file or a pipe while it waits for a
# connection, as does a line before a sleep, with tasks and without.
# timeout: 180
# builds: shared
source "$ROOT/test/cli/_lib.sh"

cat >srv.rig <<'EOF'
use std.http
use std.net

sub main()!
  l = net.listen("127.0.0.1:0")!
  print("listening on", l.port())
  http.serve(<l, |req| http.text(req.path))!
EOF

cat >nap.rig <<'EOF'
use std.time

sub main()!
  print("before the nap")
  time.sleep(60 * time.SECOND)!
EOF

cat >tasknap.rig <<'EOF'
use std.time

fun nap() -> Int!
  time.sleep(60 * time.SECOND)!
  1

sub main()!
  t = nap()&
  print("before the wait")
  print(>t!)
EOF

# first_line <program> <out>: start the program with stdout to a file,
# wait up to 10 seconds for a line in it, then end the program.
first_line() {
    "./$1" >"$2" 2>&1 &
    local pid=$! i
    for i in $(seq 1 100); do
        [[ -s $2 ]] && break
        sleep 0.1
    done
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    head -1 "$2"
}

for mode in debug release; do
    flag=; [[ $mode == release ]] && flag=--release
    for p in srv nap tasknap; do
        out=$(rig build $flag $p.rig 2>&1); expect_rc $? 0 "$mode build $p: $out"
    done
    expect_has "$(first_line srv srv.out)" "listening on " "$mode: a server's first line, while it waits"
    expect_eq "$(first_line nap nap.out)" "before the nap" "$mode: a line before a sleep"
    expect_eq "$(first_line tasknap tasknap.out)" "before the wait" "$mode: a line before a task's wait"
done
exit 0
