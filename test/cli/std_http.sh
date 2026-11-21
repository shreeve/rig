# std.http.serve's limits, with a client in Python: an idle connection
# and a slow request head are closed after their timeouts, a stalled
# body after the idle one, and a body that keeps coming but is not
# whole by its deadline then; bodies up to the limit are read and larger
# ones answered 413, chunked or not; a request's body is framed as RFC
# 9112 says, and a head it refuses is answered 400, as is an HTTP/1.1
# request that does not name its host once; CONNECT is answered 405;
# `Connection` is read as a list of options; and running out of
# descriptors pauses accepting rather than ending the server. The limits are set
# small through the environment (RIG_HTTP_IDLE_MS, RIG_HTTP_HEAD_MS,
# RIG_HTTP_BODY_MS, RIG_HTTP_MAX_BODY); in debug and --release.
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

def deadline():
    # A body must be whole 1 s after its head; a wait may last 5 s.
    p, port = start({'RIG_HTTP_IDLE_MS': '5000', 'RIG_HTTP_BODY_MS': '1000'})
    try:
        out = []
        def trickle(name, head, body):
            """Send `body` a byte every 50 ms, each wait far shorter than
            the idle time, until the server closes: what it answered, and
            whether it closed at about the body's deadline."""
            s = conn(port)
            s.sendall(head)
            t = time.monotonic()
            s.setblocking(False)
            got = None
            for b in body:
                time.sleep(0.05)
                try:
                    got = s.recv(4096)
                    break
                except BlockingIOError:
                    pass
                except OSError:
                    got = b''
                    break
                try:
                    s.send(bytes([b]))
                except OSError:
                    got = b''
                    break
            elapsed = time.monotonic() - t
            s.close()
            out.append('%s %r %s' % (name, got, 0.9 < elapsed < 4))
        post = b'POST /t HTTP/1.1\r\nHost: x\r\n'
        trickle('chunks', post + b'Transfer-Encoding: chunked\r\n\r\n', b'1\r\nz\r\n' * 30)
        trickle('extensions', post + b'Transfer-Encoding: chunked\r\n\r\n', b'1;' + b'x' * 180)
        trickle('length', post + b'Content-Length: 500\r\n\r\n', b'z' * 180)
        # A body that comes in pieces and is whole before its deadline
        # is answered, and so is the next on its connection, past the
        # first one's deadline: each body has its own.
        s = conn(port)
        for _ in range(2):
            s.sendall(post + b'Transfer-Encoding: chunked\r\n\r\n')
            for piece in [b'3\r\nab', b'c\r\n', b'0\r\n\r\n']:
                time.sleep(0.05)
                s.sendall(piece)
            got = b''
            while not got.endswith(b'/t 3'):
                b = s.recv(4096)
                if not b:
                    break
                got += b
            out.append('whole %s %s' % (status(got), body(got)))
            time.sleep(1.0)
        s.close()
        print('\n'.join(out))
    finally:
        p.kill()

def answers(got):
    """Each answer in `got`: its status, its body, and what it says of
    the connection, `close` or `keep-alive`."""
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
                close = ' ' + value.decode()
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
        # A header name that is no token, as one with a space or a tab
        # before its colon, or a line with no colon: 400.
        send('space before colon', b'POST /c HTTP/1.1\r\n' + h + b'Content-Length : 3\r\n\r\nabc' + nxt)
        send('tab before colon', b'POST /c HTTP/1.1\r\n' + h + b'Transfer-Encoding\t: chunked\r\n\r\n0\r\n\r\n' + nxt)
        send('name with a space', b'GET /c HTTP/1.1\r\n' + h + b'X Y: a\r\n\r\n' + nxt)
        send('no colon', b'GET /c HTTP/1.1\r\n' + h + b'Weird\r\n\r\n' + nxt)
        # A body is read whatever the method.
        send('get, length 0', b'GET /m HTTP/1.1\r\n' + h + b'Content-Length: 0\r\n\r\n' + nxt)
        send('get, length 2', b'GET /m HTTP/1.1\r\n' + h + b'Content-Length: 2\r\n\r\nab' + nxt)
        send('delete, length 2', b'DELETE /m HTTP/1.1\r\n' + h + b'Content-Length: 2\r\n\r\n{}' + nxt)
        send('options, chunked', b'OPTIONS /m HTTP/1.1\r\n' + h + b'Transfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n0\r\n\r\n' + nxt)
        # Chunks as RFC 9112 writes them; every other form is 400, and a
        # size past the limit 413.
        te = b'POST /k HTTP/1.1\r\n' + h + b'Transfer-Encoding: chunked\r\n\r\n'
        send('chunk extension', te + b'3;x=y\r\nabc\r\n0\r\n\r\n' + nxt)
        send('trailers', te + b'3\r\nabc\r\n0\r\nA: b\r\nC: d\r\n\r\n' + nxt)
        send('chunk size 2^64-1', te + b'FFFFFFFFFFFFFFFF\r\nX')
        send('chunk size 17 digits', te + b'00000000000000003\r\nabc\r\n0\r\n\r\n' + nxt)
        send('chunk bare lf', te + b'3\nabc\r\n0\r\n\r\n' + nxt)
        send('chunk no size', te + b'\r\n' + nxt)
        send('chunk size g', te + b'1g\r\n' + nxt)
        send('chunk size spaced', te + b' 3\r\nabc\r\n0\r\n\r\n' + nxt)
        send('chunk data unended', te + b'3\r\nabcXX0\r\n\r\n' + nxt)
        send('short trailer', te + b'0\r\na:b\r\nGET /smuggled HTTP/1.1\r\nX: y\r\n\r\n' + nxt)
        # A body cut short is not whole: no answer.
        send('length cut short', b'POST /k HTTP/1.1\r\n' + h + b'Content-Length: 10\r\n\r\nabc', half=True)
        send('chunks cut short', te + b'3\r\nabc\r\n', half=True)
        # HTTP/1.0 with chunks closes after its answer.
        send('1.0 chunked', b'POST /k HTTP/1.0\r\nConnection: keep-alive\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n0\r\n\r\n' + nxt)
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
        # `Connection` is a list of options, over every line of it: an
        # HTTP/1.1 connection closes when one is `close`; an HTTP/1.0
        # connection goes on only when one is `keep-alive` and none is
        # `close`, and its client is told so.
        get = b'GET /o HTTP/1.1\r\n' + h
        send('close, TE', get + b'Connection: close, TE\r\n\r\n' + nxt)
        send('keep-alive, close', get + b'Connection: keep-alive, close\r\n\r\n' + nxt)
        send('TE,CLOSE', get + b'Connection: TE,\tCLOSE\r\n\r\n' + nxt)
        send('close, then keep-alive', get + b'Connection: close\r\nConnection: keep-alive\r\n\r\n' + nxt)
        send('upgrade', get + b'Connection: Upgrade\r\n\r\n' + nxt)
        old = b'GET /o HTTP/1.0\r\n'
        send('1.0', old + b'\r\n' + nxt)
        send('1.0 keep-alive', old + b'Connection: Keep-Alive\r\n\r\n' + nxt)
        send('1.0 upgrade', old + b'Connection: Upgrade\r\n\r\n' + nxt)
        send('1.0 upgrade, keep-alive', old + b'Connection: Upgrade, keep-alive\r\n\r\n' + nxt)
        send('1.0 keep-alive, close', old + b'Connection: keep-alive, close\r\n\r\n' + nxt)
        send('1.0 upgrade, then keep-alive', old + b'Connection: Upgrade\r\nConnection: keep-alive\r\n\r\n' + nxt)
        # An HTTP/1.1 request names its host once: none, or two in any
        # version, is 400. An HTTP/1.0 request needs none.
        send('no host', b'GET /h HTTP/1.1\r\n\r\n' + nxt)
        send('no host, post', b'POST /h HTTP/1.1\r\nContent-Length: 3\r\n\r\nabc' + nxt)
        send('two hosts', b'GET /h HTTP/1.1\r\n' + h + b'A: b\r\nhost: y\r\n\r\n' + nxt)
        send('1.0 two hosts', old + h + h + b'Connection: keep-alive\r\n\r\n' + nxt)
        send('1.0 host', old + h + b'\r\n' + nxt)
        send('empty host', b'GET /h HTTP/1.1\r\nHost:\r\n\r\n' + nxt)
        # CONNECT asks for a tunnel: 405, before the handler.
        send('connect', b'CONNECT h:443 HTTP/1.1\r\nHost: h:443\r\n\r\n' + nxt)
        send('connect, a body', b'CONNECT h:443 HTTP/1.1\r\nHost: h:443\r\nContent-Length: 3\r\n\r\nabc' + nxt)
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

{'limits': limits, 'deadline': deadline, 'framing': framing, 'descriptors': descriptors}[sys.argv[1]]()
EOF2

# The default timeouts on a deterministic run's virtual clock: an idle
# connection closes after 60 s, one kept alive after a request 60 s
# after it, a head that stops partway 10 s after its first byte, and a
# connection that asks every 5 s for 100 s, past its first 60 s, 60 s
# after its last request: its deadline moved with each; and one that
# sends a body a byte every 30 s 300 s after the body's head, not 60 s
# after its last byte.
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
  t0 = time.monotonic()
  if first.len > 0
    (!c).write(first)!
  got = String()
  while (!c).read(!got, 4096)! > 0
    pass
  t0.elapsed().ns() / 1_000_000_000

# Seconds until the server closes `c` after the last of 21 requests,
# each answered, and 5 s apart.
fun kept(port: Int) -> Int!
  c = net.connect(String("127.0.0.1:", port))!
  got = String()
  for 0..20
    (!c).write("GET /k HTTP/1.1\r\nHost: x\r\n\r\n")!
    _ = (!c).read(!got, 4096)!
    time.sleep(5)!
  t0 = time.monotonic()
  (!c).write("GET /k HTTP/1.1\r\nHost: x\r\n\r\n")!
  while (!c).read(!got, 4096)! > 0
    pass
  t0.elapsed().ns() / 1_000_000_000

# Seconds until the server closes `c`, which sends the head of a
# chunked body, then a byte of it every 30 s, nine of them.
fun trickled(port: Int) -> Int!
  c = net.connect(String("127.0.0.1:", port))!
  t0 = time.monotonic()
  (!c).write("POST /t HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n")!
  for 0..9
    time.sleep(30)!
    (!c).write("1")!
  got = String()
  while (!c).read(!got, 4096)! > 0
    pass
  t0.elapsed().ns() / 1_000_000_000

sub main()!
  l = net.listen("127.0.0.1:0")!
  port = l.port()
  t = run(<l)&
  print(closes(port, "")!, closes(port, "GET /k HTTP/1.1\r\nHost: x\r\n\r\n")!, closes(port, "GET / HTTP/1.1\r\nHo")!, kept(port)!, trickled(port)!)
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
want_deadline="chunks b'' True
extensions b'' True
length b'' True
whole 200 /t 3
whole 200 /t 3"
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
space before colon: 400 bad request close
tab before colon: 400 bad request close
name with a space: 400 bad request close
no colon: 400 bad request close
get, length 0: 200 /m 0, 200 /next 0 close
get, length 2: 200 /m 2, 200 /next 0 close
delete, length 2: 200 /m 2, 200 /next 0 close
options, chunked: 200 /m 3, 200 /next 0 close
chunk extension: 200 /k 3, 200 /next 0 close
trailers: 200 /k 3, 200 /next 0 close
chunk size 2^64-1: 413 content too large close
chunk size 17 digits: 400 bad request close
chunk bare lf: 400 bad request close
chunk no size: 400 bad request close
chunk size g: 400 bad request close
chunk size spaced: 400 bad request close
chunk data unended: 400 bad request close
short trailer: 400 bad request close
length cut short: none
chunks cut short: none
1.0 chunked: 200 /k 3 close
bare lf line: 400 bad request close
unknown method: 400 bad request close
empty line: 200 /e 0, 200 /next 0 close
two empty lines: 200 /e 0, 200 /next 0 close
three empty lines: 400 bad request close
empty line after a body: 200 /l 3, 200 /next 0 close
two after a body: 200 /l 3, 200 /next 0 close
empty line, then close: 200 /l 3
bare lf line before: 400 bad request close
close, TE: 200 /o 0 close
keep-alive, close: 200 /o 0 close
TE,CLOSE: 200 /o 0 close
close, then keep-alive: 200 /o 0 close
upgrade: 200 /o 0, 200 /next 0 close
1.0: 200 /o 0 close
1.0 keep-alive: 200 /o 0 keep-alive, 200 /next 0 close
1.0 upgrade: 200 /o 0 close
1.0 upgrade, keep-alive: 200 /o 0 keep-alive, 200 /next 0 close
1.0 keep-alive, close: 200 /o 0 close
1.0 upgrade, then keep-alive: 200 /o 0 keep-alive, 200 /next 0 close
no host: 400 bad request close
no host, post: 400 bad request close
two hosts: 400 bad request close
1.0 two hosts: 400 bad request close
1.0 host: 200 /o 0 close
empty host: 200 /h 0, 200 /next 0 close
connect: 405 method not allowed close
connect, a body: 405 method not allowed close
after: 200 /next 0 close
alive True"
for mode in debug release; do
    flag=; [[ $mode == release ]] && flag=--release
    out=$(rig build $flag srv.rig 2>&1); expect_rc $? 0 "$mode build: $out"
    out=$(python3 client.py limits 2>&1); expect_rc $? 0 "$mode limits: $out"
    expect_eq "$out" "$want_limits" "$mode: timeouts and the body limit"
    out=$(python3 client.py deadline 2>&1); expect_rc $? 0 "$mode deadline: $out"
    expect_eq "$out" "$want_deadline" "$mode: a body's deadline"
    out=$(python3 client.py framing 2>&1); expect_rc $? 0 "$mode framing: $out"
    expect_eq "$out" "$want_framing" "$mode: request framing"
    out=$(python3 client.py descriptors 2>&1); expect_rc $? 0 "$mode descriptors: $out"
    expect_eq "$out" $'held True\n200 /again 0\nalive True' "$mode: out of descriptors, it accepts again"
    # 20 seeds at once, so the machine is loaded while each clock jumps.
    out=$(rig build $flag virtual.rig 2>&1); expect_rc $? 0 "$mode build virtual: $out"
    for seed in $(seq 1 20); do
        (RIG_SEED=$seed "$TIMEOUT_CMD" 120 ./virtual >"virtual-$seed.out" 2>&1; echo "rc $?" >>"virtual-$seed.out") &
    done
    wait
    for seed in $(seq 1 20); do
        expect_eq "$(cat virtual-$seed.out)" $'60 60 10 60 300\nrc 0' "$mode: the default timeouts, seed $seed"
    done
done
exit 0
