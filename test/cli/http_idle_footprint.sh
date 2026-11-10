# What an idle connection of std.http.serve costs, as the kernel counts
# it (`footprint` on macOS, VmRSS and VmPTE on Linux), page tables
# included: its task waits on a dense stack, which shares page tables
# with its neighbours, where a large stack holds a page table of its own
# (16 KiB on the Mac, 4 KiB on Linux). 2,000 connections each make one
# request and stay open; the server's growth over them, per connection,
# is what one costs. A release build, which dense stacks need.
# timeout: 240
source "$ROOT/test/cli/_lib.sh"

cat >srv.rig <<'EOF2'
use std.http
use std.net

sub main()!
  l = net.listen("127.0.0.1:0")!
  warn(l.port())
  http.serve(<l, |req| http.text(String(req.path)))!
EOF2

out=$(rig build --release -o srv srv.rig 2>&1) || fail "build: $out"

cat >client.py <<'EOF2'
import platform, re, socket, subprocess, sys, time

MAC = platform.system() == "Darwin"
N = 2000

def sample(pid):
    """The process's memory and its page tables, in bytes."""
    if MAC:
        out = subprocess.run(["footprint", "-p", str(pid), "-f", "bytes"], capture_output=True, text=True).stdout
        total = tables = 0
        for line in out.splitlines():
            m = re.match(r"\s*(\d+) B\s+\d+ B\s+\d+ B\s+\d+\s+(.*)$", line)
            if m and m.group(2).strip() == "TOTAL":
                total = int(m.group(1))
            elif m and m.group(2).strip() == "page table":
                tables = int(m.group(1))
        return total, tables
    rss = pte = 0
    for line in open("/proc/%d/status" % pid):
        if line.startswith("VmRSS:"):
            rss = int(line.split()[1]) * 1024
        elif line.startswith("VmPTE:"):
            pte = int(line.split()[1]) * 1024
    return rss + pte, pte

def request(port):
    s = socket.create_connection(("127.0.0.1", port))
    s.sendall(b"GET /x HTTP/1.1\r\nHost: a\r\n\r\n")
    got = b""
    while not got.endswith(b"/x"):
        b = s.recv(4096)
        if not b:
            sys.exit("the server closed a connection")
        got += b
    return s

p = subprocess.Popen(["./srv"], stderr=subprocess.PIPE)
port = int(p.stderr.readline())
try:
    warm = [request(port) for _ in range(50)]
    time.sleep(0.5)
    before, tables_before = sample(p.pid)
    held = [request(port) for _ in range(N)]
    time.sleep(0.5)
    after, tables_after = sample(p.pid)
    print("%.1f %.2f" % ((after - before) / N / 1024, (tables_after - tables_before) / N / 1024))
finally:
    p.kill()
    p.wait()
EOF2

got=$(ulimit -n 8192 2>/dev/null; python3 client.py 2>&1) || fail "client: $got"
read -r per tables <<<"$got"
[[ -n $tables ]] || fail "client printed: $got"
echo "per idle connection: $per KiB, of it page tables $tables KiB"
# A large stack each: 16 KiB of page table on the Mac and 4 KiB on
# Linux. A dense stack: under 1 KiB on either.
awk -v t="$tables" 'BEGIN { exit !(t < 2) }' || fail "page tables per idle connection: $tables KiB (2 or more: its task holds a large stack)"
if [[ $(uname -s) == Darwin ]]; then limit=24; else limit=11; fi
awk -v p="$per" -v l="$limit" 'BEGIN { exit !(p < l) }' || fail "per idle connection: $per KiB, $limit or more"
exit 0
