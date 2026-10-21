# std.http.serve's limits, with a client in Python: an idle connection
# and a slow request head are closed after their timeouts, a stalled
# body after the idle one; bodies up to the limit are read and larger
# ones answered 413, chunked or not; and running out of descriptors
# pauses accepting rather than ending the server. The limits are set
# small through the environment (RIG_HTTP_IDLE_MS, RIG_HTTP_HEAD_MS,
# RIG_HTTP_MAX_BODY); in debug and --release.
# timeout: 300
source "$ROOT/test/cli/_lib.sh"

cat >srv.rig <<'EOF2'
use std.http
use std.net

sub main()!
  l = net.listen("127.0.0.1:0")!
  # stderr, which is not buffered.
  warn(l.port())
  http.serve(<l, |req| http.text(String(req.path, " ", req.body.len)))!
EOF2

cat >client.py <<'EOF2'
import os, socket, subprocess, sys, time

def start(env, limit=None):
    cmd = ['./srv'] if limit is None else ['bash', '-c', 'ulimit -n %d; exec ./srv' % limit]
    p = subprocess.Popen(cmd, stderr=subprocess.PIPE, env={**os.environ, **env})
    return p, int(p.stderr.readline())

def conn(port):
    s = socket.create_connection(('127.0.0.1', port))
    s.settimeout(10)
    return s

def read_all(s):
    got = b''
    while True:
        try:
            b = s.recv(65536)
        except ConnectionResetError:
            return got + b'<reset>'
        if not b:
            return got
        got += b

def closed_after(s):
    """Seconds until the server closes `s`, reading what it sends."""
    t = time.monotonic()
    read_all(s)
    return time.monotonic() - t

def status(got):
    pre = '(100) ' if got.startswith(b'(100) ') else ''
    got = got[len(pre):]
    return pre + (got.split(b' ', 2)[1].decode() if got.startswith(b'HTTP/1.1 ') else repr(got[:40]))

def body(got):
    return got.split(b'\r\n\r\n', 1)[1].decode().strip()

def ask(port, req, then=b''):
    s = conn(port)
    s.sendall(req)
    if then:
        time.sleep(0.05)
        s.sendall(then)
    got = read_all(s)
    s.close()
    # What `100 Continue` asked for is answered after it.
    if got.startswith(b'HTTP/1.1 100 Continue\r\n\r\n'):
        got = b'(100) ' + got[25:]
    return status(got) + ' ' + body(got)

def chunked(n):
    return b'POST /c HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n' + \
        b'%x\r\n' % n + b'z' * n + b'\r\n0\r\n\r\n'

def post(n, extra=b''):
    return b'POST /p HTTP/1.1\r\nHost: x\r\nContent-Length: %d\r\nConnection: close\r\n%s\r\n' % (n, extra)

def limits():
    p, port = start({'RIG_HTTP_IDLE_MS': '300', 'RIG_HTTP_HEAD_MS': '600', 'RIG_HTTP_MAX_BODY': '1000'})
    try:
        out = []
        # Idle: a connection that never sends, and one kept alive after
        # a request.
        t = closed_after(conn(port))
        out.append('idle %s' % (0.2 < t < 3))
        s = conn(port)
        s.sendall(b'GET /k HTTP/1.1\r\nHost: x\r\n\r\n')
        t = time.monotonic()
        got = read_all(s)
        out.append('kept %s %s' % (status(got), 0.2 < time.monotonic() - t < 3))
        # A head sent a byte every 100 ms, each wait shorter than the idle
        # timeout, is cut off by the head timeout.
        s = conn(port)
        t = time.monotonic()
        s.sendall(b'GET / HTTP/1.1\r\n')
        cut = False
        for _ in range(40):
            time.sleep(0.1)
            try:
                s.sendall(b'X')
            except OSError:
                cut = True
                break
        elapsed = time.monotonic() - t
        out.append('head %s' % ((cut or read_all(s) == b'') and 0.4 < elapsed < 3))
        # A body that stops partway.
        s = conn(port)
        s.sendall(post(10) + b'abc')
        t = closed_after(s)
        out.append('stalled %s' % (0.2 < t < 3))
        # The body limit, with Content-Length and chunked.
        out.append(ask(port, post(1000) + b'y' * 1000))
        out.append(ask(port, post(1001) + b'y' * 1001))
        out.append(ask(port, chunked(1000)))
        out.append(ask(port, chunked(1001)))
        out.append(ask(port, post(1000, b'Expect: 100-continue\r\n'), b'y' * 1000))
        out.append(ask(port, post(5000, b'Expect: 100-continue\r\n')))
        out.append(ask(port, b'GET /after HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n'))
        print('\n'.join(out))
    finally:
        p.kill()

def descriptors():
    # The server may hold 512 descriptors (its workers' pollers take some
    # of them): the 700 connections held open take the rest, and it
    # accepts again once they close.
    import resource
    soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
    want = 2048 if hard == resource.RLIM_INFINITY else min(2048, hard)
    resource.setrlimit(resource.RLIMIT_NOFILE, (max(soft, want), hard))
    p, port = start({}, limit=512)
    try:
        # Once the backlog fills too, the system may refuse more.
        held = []
        try:
            for _ in range(700):
                held.append(conn(port))
        except OSError:
            pass
        print('held', len(held) > 512)
        time.sleep(0.3)
        for s in held:
            s.close()
        time.sleep(0.2)
        print(ask(port, b'GET /again HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n'))
        print('alive', p.poll() is None)
    finally:
        p.kill()

{'limits': limits, 'descriptors': descriptors}[sys.argv[1]]()
EOF2

# The default timeouts on a deterministic run's virtual clock: an idle
# connection closes after 60 s, one kept alive after a request 60 s
# after it, and a head that stops partway 10 s after its first byte.
cat >virtual.rig <<'EOF2'
use std.http
use std.net
use std.time

fun run(l: net.Listener) -> Int!
  http.serve(<l, |req| http.text(req.path))!
  0

# Seconds until the server closes `c`, after it sends `first`.
fun closes(port: Int, first: ?String) -> Int!
  c = net.connect(String("127.0.0.1:", port))!
  t0 = time.now()
  if first.len > 0
    (!c).write(first)!
  got = String()
  while (!c).read(!got, 4096)! > 0
    pass
  t0.elapsed() / time.SECOND

sub main()!
  l = net.listen("127.0.0.1:0")!
  port = l.port()
  t = run(<l)&
  print(closes(port, "")!, closes(port, "GET /k HTTP/1.1\r\nHost: x\r\n\r\n")!, closes(port, "GET / HTTP/1.1\r\nHo")!)
  _ = <t.cancel() catch -1
EOF2

want_limits='idle True
kept 200 True
head True
stalled True
200 /p 1000
413 content too large
200 /c 1000
413 content too large
(100) 200 /p 1000
413 content too large
200 /after 0'
for mode in debug release; do
    flag=; [[ $mode == release ]] && flag=--release
    out=$(rig build $flag srv.rig 2>&1); expect_rc $? 0 "$mode build: $out"
    out=$(python3 client.py limits 2>&1); expect_rc $? 0 "$mode limits: $out"
    expect_eq "$out" "$want_limits" "$mode: timeouts and the body limit"
    out=$(python3 client.py descriptors 2>&1); expect_rc $? 0 "$mode descriptors: $out"
    expect_eq "$out" $'held True\n200 /again 0\nalive True' "$mode: out of descriptors, it accepts again"
    # 20 seeds at once, so the machine is loaded while each clock jumps.
    out=$(rig build $flag virtual.rig 2>&1); expect_rc $? 0 "$mode build virtual: $out"
    for seed in $(seq 1 20); do
        (RIG_SEED=$seed "$TIMEOUT_CMD" 120 ./virtual >"virtual-$seed.out" 2>&1; echo "rc $?" >>"virtual-$seed.out") &
    done
    wait
    for seed in $(seq 1 20); do
        expect_eq "$(cat virtual-$seed.out)" $'60 60 10\nrc 0' "$mode: the default timeouts, seed $seed"
    done
done
exit 0
