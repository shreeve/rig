# std.http.serve's limits, with a client in Python: an idle connection
# and a slow request head are closed after their timeouts, a stalled
# body after the idle one; bodies up to the limit are read and larger
# ones answered 413, chunked or not; a request's body is framed as RFC
# 9112 says, and a head it refuses is answered 400; and running out of
# descriptors pauses accepting rather than ending the server. The limits are set
# small through the environment (RIG_HTTP_IDLE_MS, RIG_HTTP_HEAD_MS,
# RIG_HTTP_MAX_BODY); in debug and --release. On several workers, every
# worker accepts, none takes more than its share, and a worker stuck in
# one long call (a std module of the test's own, through RIG_STD) does
# not hold up the connections it took.
# timeout: 300
# builds: shared
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
import os, re, socket, subprocess, sys, time

def start(env, limit=None, exe='./srv'):
    cmd = [exe] if limit is None else ['bash', '-c', 'ulimit -n %d; exec %s' % (limit, exe)]
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
        # Many requests, each sooner than the idle timeout after the last,
        # for longer than it, then none: closed after the idle timeout.
        s = conn(port)
        t = time.monotonic()
        answered = 0
        while time.monotonic() - t < 1.0:
            s.sendall(b'GET /q HTTP/1.1\r\nHost: x\r\n\r\n')
            got = b''
            while not got.endswith(b'/q 0'):
                b = s.recv(4096)
                if not b:
                    break
                got += b
            if not got.endswith(b'/q 0'):
                break
            answered += 1
            time.sleep(0.02)
        t = closed_after(s)
        out.append('moved %s %s' % (answered > 20, 0.2 < t < 3))
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

def answers(got):
    """Each answer in `got`: its status, its body, and `close` when it
    says the connection closes."""
    out = []
    while got.startswith(b'HTTP/1.1 '):
        head, _, rest = got.partition(b'\r\n\r\n')
        lines = head.split(b'\r\n')
        n = 0
        close = ''
        for line in lines[1:]:
            name, _, value = line.partition(b': ')
            if name == b'content-length':
                n = int(value)
            if name == b'connection':
                close = ' close'
        out.append(lines[0].split(b' ', 2)[1].decode() + ' ' + rest[:n].decode().strip() + close)
        got = rest[n:]
    if got:
        out.append(repr(got[:40]))
    return ', '.join(out) or 'none'

def framing():
    p, port = start({'RIG_HTTP_IDLE_MS': '3000'})
    try:
        out = []
        def send(name, req, half=False):
            s = conn(port)
            s.sendall(req)
            if half:
                s.shutdown(socket.SHUT_WR)
            t = time.monotonic()
            got = answers(read_all(s))
            s.close()
            out.append('%s: %s%s' % (name, got, '' if time.monotonic() - t < 2 else ' (slow)'))
        h = b'Host: x\r\n'
        nxt = b'GET /next HTTP/1.1\r\n' + h + b'Connection: close\r\n\r\n'
        # Neither a length nor chunked: no body, whatever the method.
        send('no length', b'POST /p HTTP/1.1\r\n' + h + b'\r\n' + nxt)
        send('no length, put', b'PUT /p HTTP/1.1\r\n' + h + b'\r\n' + nxt)
        send('no length, half-closed', b'POST /p HTTP/1.1\r\n' + h + b'\r\n', half=True)
        # A Transfer-Encoding that does not end in chunked: 400.
        send('gzip', b'GET /g HTTP/1.1\r\n' + h + b'Transfer-Encoding: gzip\r\n\r\n' + nxt)
        send('gzip, post', b'POST /g HTTP/1.1\r\n' + h + b'Transfer-Encoding: gzip\r\n\r\n' + nxt, half=True)
        send('chunked, gzip', b'POST /g HTTP/1.1\r\n' + h + b'Transfer-Encoding: chunked, gzip\r\n\r\n0\r\n\r\n' + nxt)
        send('none', b'GET /g HTTP/1.1\r\n' + h + b'Transfer-Encoding: none\r\n\r\n' + nxt)
        send('gzip, chunked', b'POST /g HTTP/1.1\r\n' + h + b'Transfer-Encoding: gzip, chunked\r\n\r\n0\r\n\r\n' + nxt)
        # Coding names in any case.
        for v in [b'Chunked', b'CHUNKED', b'gzip, Chunked', b'gzip,\tchunked', b'Chunked, gzip']:
            send(v.decode().replace('\t', ' '), b'POST /g HTTP/1.1\r\n' + h + b'Transfer-Encoding: ' + v + b'\r\n\r\n3\r\nabc\r\n0\r\n\r\n' + nxt)
        # A length and chunked: read as chunked, then closed.
        send('both', b'POST /b HTTP/1.1\r\n' + h + b'Content-Length: 4\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\nGET /smuggled HTTP/1.1\r\n' + h + b'\r\n')
        # A length that is not digits: 400.
        for v in [b'1_0', b'+3', b'-0', b'0x3', b' ']:
            send('length %r' % v.decode(), b'POST /l HTTP/1.1\r\n' + h + b'Content-Length: ' + v + b'\r\n\r\nabcdefghij' + nxt)
        send('length 007', b'POST /l HTTP/1.1\r\n' + h + b'Content-Length: 007\r\n\r\nabcdefg' + nxt)
        # A CR, LF, or NUL that ends no line: 400.
        send('bare lf', b'POST /c HTTP/1.1\r\n' + h + b'X: a\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n' + nxt)
        send('bare cr', b'GET /c HTTP/1.1\r\n' + h + b'X: a\rb\r\n\r\n' + nxt)
        send('nul', b'GET /c HTTP/1.1\r\n' + h + b'X: a\x00b\r\n\r\n' + nxt)
        send('bare lf line', b'GET /c HTTP/1.1\n' + h + b'\r\n' + nxt)
        send('unknown method', b'BREW /c HTTP/1.1\r\n' + h + b'\r\n' + nxt)
        # Up to two empty lines before a request line are skipped.
        send('empty line', b'\r\nGET /e HTTP/1.1\r\n' + h + b'\r\n' + nxt)
        send('two empty lines', b'\r\n\r\nGET /e HTTP/1.1\r\n' + h + b'\r\n' + nxt)
        send('three empty lines', b'\r\n\r\n\r\nGET /e HTTP/1.1\r\n' + h + b'\r\n' + nxt)
        send('empty line after a body', b'POST /l HTTP/1.1\r\n' + h + b'Content-Length: 3\r\n\r\nabc\r\n' + nxt)
        send('two after a body', b'POST /l HTTP/1.1\r\n' + h + b'Content-Length: 3\r\n\r\nabc\r\n\r\n' + nxt)
        send('empty line, then close', b'POST /l HTTP/1.1\r\n' + h + b'Content-Length: 3\r\n\r\nabc\r\n', half=True)
        send('bare lf line before', b'\nGET /e HTTP/1.1\r\n' + h + b'\r\n' + nxt)
        send('after', nxt)
        out.append('alive %s' % (p.poll() is None))
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
        # The server accepts again once it sees the closes, which a loaded
        # machine may take a moment to deliver: ask until it answers, for
        # up to 2 s.
        again = b'GET /again HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n'
        deadline = time.time() + 2
        while True:
            time.sleep(0.1)
            try:
                got = ask(port, again)
            except OSError as e:
                got = 'error ' + str(e)
            if got.startswith('200') or time.time() > deadline:
                break
        print(got)
        print('alive', p.poll() is None)
    finally:
        p.kill()

def answered(s, path):
    """Ask for `path` on `s`, kept open, and read its answer."""
    s.sendall(b'GET %s HTTP/1.1\r\nHost: x\r\n\r\n' % path)
    got = b''
    while True:
        head, sep, rest = got.partition(b'\r\n\r\n')
        if sep:
            m = re.search(rb'content-length: (\d+)', head, re.I)
            if m and len(rest) >= int(m.group(1)):
                return rest.decode()
        b = s.recv(4096)
        if not b:
            return repr(got)
        got += b

def spread():
    # Four workers, 64 connections at once: every worker takes some, and
    # none more than an eighth over the average and 2 (20), as each
    # acceptor writes with RIG_SCHED_STATS=1.
    p, port = start({'RIG_WORKERS': '4', 'RIG_SCHED_STATS': '1'})
    try:
        socks = [conn(port) for _ in range(64)]
        ok = sum(answered(s, b'/s') == '/s 0' for s in socks)
        for s in socks:
            s.close()
        time.sleep(0.2)
    finally:
        p.kill()
    took = {}
    for m in re.finditer(r'rig: serve: worker (\d+): accepted (\d+), holds (\d+)', p.stderr.read().decode()):
        took[int(m.group(1))] = int(m.group(2))
    print('answered', ok)
    print('owners', len(took), 'within', bool(took) and max(took.values()) <= 20)

def stuck():
    # Two workers, 40 connections; one request holds the worker running
    # it for 1.5 s in a call that makes no yield check and that no signal
    # stops. The connections the other worker took, and those the stuck
    # one took, are answered meanwhile: a sleeping worker looks at the
    # stuck one's poller.
    p, port = start({'RIG_WORKERS': '2'}, exe='./stuck')
    try:
        socks = [conn(port) for _ in range(40)]
        warm = all(answered(s, b'/w') == '/w 0' for s in socks)
        t0 = time.monotonic()
        socks[0].sendall(b'GET /stall HTTP/1.1\r\nHost: x\r\n\r\n')
        time.sleep(0.2)
        ok = all(answered(s, b'/q') == '/q 0' for s in socks[1:])
        during = time.monotonic() - t0 < 1.2
        socks[0].settimeout(10)
        got = b''
        while not got.endswith(b'/stall 1'):
            b = socks[0].recv(4096)
            if not b:
                break
            got += b
        print('warm', warm, 'answered', ok, 'during', during, 'stalled', got.endswith(b'/stall 1') and time.monotonic() - t0 > 1.4)
    finally:
        p.kill()

{'limits': limits, 'framing': framing, 'descriptors': descriptors, 'spread': spread, 'stuck': stuck}[sys.argv[1]]()
EOF2

# A server whose handler holds its worker for 1.5 s on /stall, spinning
# in Zig code: no yield check, and a preemption signal declined.
cp -R "$ROOT/std" lib
printf 'extern zig "stall.zig"\n  pub fun hold(path: ?String) -> Int\n' >lib/stall.rig
cat >lib/stall.zig <<'EOF2'
const std = @import("std");
const rig = @import("../runtime.zig");

pub fn hold(path: []const u8) i64 {
    if (!std.mem.eql(u8, path, "/stall")) return 0;
    const end = rig.sched.nowNs() + 1500 * std.time.ns_per_ms;
    while (rig.sched.nowNs() < end) std.atomic.spinLoopHint();
    return 1;
}
EOF2
cat >stuck.rig <<'EOF2'
use std.http
use std.net
use std.stall

sub main()!
  l = net.listen("127.0.0.1:0")!
  warn(l.port())
  http.serve(<l, |req| http.text(String(req.path, " ", stall.hold(req.path))))!
EOF2

# The default timeouts on a deterministic run's virtual clock: an idle
# connection closes after 60 s, one kept alive after a request 60 s
# after it, a head that stops partway 10 s after its first byte, and a
# connection that asks every 5 s for 100 s, past its first 60 s, 60 s
# after its last request: its deadline moved with each.
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

# Seconds until the server closes `c` after the last of 21 requests,
# each answered, and 5 s apart.
fun kept(port: Int) -> Int!
  c = net.connect(String("127.0.0.1:", port))!
  got = String()
  for 0..20
    (!c).write("GET /k HTTP/1.1\r\nHost: x\r\n\r\n")!
    _ = (!c).read(!got, 4096)!
    time.sleep(5)!
  t0 = time.now()
  (!c).write("GET /k HTTP/1.1\r\nHost: x\r\n\r\n")!
  while (!c).read(!got, 4096)! > 0
    pass
  t0.elapsed() / time.SECOND

sub main()!
  l = net.listen("127.0.0.1:0")!
  port = l.port()
  t = run(<l)&
  print(closes(port, "")!, closes(port, "GET /k HTTP/1.1\r\nHost: x\r\n\r\n")!, closes(port, "GET / HTTP/1.1\r\nHo")!, kept(port)!)
  _ = <t.cancel() catch -1
EOF2

want_limits='idle True
kept 200 True
moved True True
head True
stalled True
200 /p 1000
413 content too large
200 /c 1000
413 content too large
(100) 200 /p 1000
413 content too large
200 /after 0'
want_framing="no length: 200 /p 0, 200 /next 0 close
no length, put: 200 /p 0, 200 /next 0 close
no length, half-closed: 200 /p 0
gzip: 400 bad request close
gzip, post: 400 bad request close
chunked, gzip: 400 bad request close
none: 400 bad request close
gzip, chunked: 200 /g 0, 200 /next 0 close
Chunked: 200 /g 3, 200 /next 0 close
CHUNKED: 200 /g 3, 200 /next 0 close
gzip, Chunked: 200 /g 3, 200 /next 0 close
gzip, chunked: 200 /g 3, 200 /next 0 close
Chunked, gzip: 400 bad request close
both: 200 /b 0 close
length '1_0': 400 bad request close
length '+3': 400 bad request close
length '-0': 400 bad request close
length '0x3': 400 bad request close
length ' ': 400 bad request close
length 007: 200 /l 7, 200 /next 0 close
bare lf: 400 bad request close
bare cr: 400 bad request close
nul: 400 bad request close
bare lf line: 400 bad request close
unknown method: 400 bad request close
empty line: 200 /e 0, 200 /next 0 close
two empty lines: 200 /e 0, 200 /next 0 close
three empty lines: 400 bad request close
empty line after a body: 200 /l 3, 200 /next 0 close
two after a body: 200 /l 3, 200 /next 0 close
empty line, then close: 200 /l 3
bare lf line before: 400 bad request close
after: 200 /next 0 close
alive True"
for mode in debug release; do
    flag=; [[ $mode == release ]] && flag=--release
    out=$(rig build $flag srv.rig 2>&1); expect_rc $? 0 "$mode build: $out"
    out=$(python3 client.py limits 2>&1); expect_rc $? 0 "$mode limits: $out"
    expect_eq "$out" "$want_limits" "$mode: timeouts and the body limit"
    out=$(python3 client.py framing 2>&1); expect_rc $? 0 "$mode framing: $out"
    expect_eq "$out" "$want_framing" "$mode: request framing"
    out=$(python3 client.py descriptors 2>&1); expect_rc $? 0 "$mode descriptors: $out"
    expect_eq "$out" $'held True\n200 /again 0\nalive True' "$mode: out of descriptors, it accepts again"
    out=$(python3 client.py spread 2>&1); expect_rc $? 0 "$mode spread: $out"
    expect_eq "$out" $'answered 64\nowners 4 within True' "$mode: every worker accepts, none past its share"
    out=$(RIG_STD="$PWD/lib" rig build $flag stuck.rig 2>&1); expect_rc $? 0 "$mode build stuck: $out"
    out=$(python3 client.py stuck 2>&1); expect_rc $? 0 "$mode stuck: $out"
    expect_eq "$out" "warm True answered True during True stalled True" "$mode: a stuck worker's connections are answered"
    # 20 seeds at once, so the machine is loaded while each clock jumps.
    out=$(rig build $flag virtual.rig 2>&1); expect_rc $? 0 "$mode build virtual: $out"
    for seed in $(seq 1 20); do
        (RIG_SEED=$seed "$TIMEOUT_CMD" 120 ./virtual >"virtual-$seed.out" 2>&1; echo "rc $?" >>"virtual-$seed.out") &
    done
    wait
    for seed in $(seq 1 20); do
        expect_eq "$(cat virtual-$seed.out)" $'60 60 10 60\nrc 0' "$mode: the default timeouts, seed $seed"
    done
done
exit 0
