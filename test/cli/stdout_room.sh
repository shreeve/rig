# A worker going to sleep writes only what stdout takes at once, and
# what is left waits for stdout to have room (rt.flushBeforeWait): a
# server whose stdout is a full pipe, or a full socket, whose reader
# waits for the server's answer on a socket before it reads, answers,
# with one worker and with many, and so does one that makes no task
# (rt.flushBeforePoll), whose sleep also ends on time; a slow reader of
# a pipe, a socket, or a terminal gets every byte, each task's lines in
# order, the last ones at exit; and stdout to a regular file or
# /dev/null is written in full. A program started with stdout closed
# gets /dev/null there (rt.holdStandardDescriptors): no socket it opens
# takes stdout's number, so its prints never reach a socket, it serves,
# and its prints fail as with stdout closed. With a client in Python. In
# debug and --release.
# timeout: 300
# builds: shared
source "$ROOT/test/cli/_lib.sh"

cat >srv.rig <<'EOF2'
use std.net

fun serve(l: net.Listener) -> Int!
  c = l.accept()!
  got = String()
  _ = (!c).read(!got, 100)!
  (!c).write("pong")!
  got.len

sub main()!
  l = net.listen("127.0.0.1:0")!
  # stderr, which is not buffered.
  warn(l.port())
  print("before the answer")
  t = serve(<l)&
  n = >t!
  print("after the answer", n)
EOF2

cat >srv1.rig <<'EOF2'
use std.net

sub main()!
  l = net.listen("127.0.0.1:0")!
  warn(l.port())
  print("before the answer")
  c = l.accept()!
  got = String()
  _ = (!c).read(!got, 100)!
  (!c).write("pong")!
  print("after the answer", got.len)
EOF2

cat >nap.rig <<'EOF2'
use std.net
use std.os
use std.time

sub main()!
  c = net.connect(os.args()[1])!
  print("before the sleep")
  time.sleep(ms: 50)!
  (!c).write("awake")!
  print("after the sleep")
EOF2

cat >talk.rig <<'EOF2'
use std.os
use std.text
use std.time

fun talk(id: Int, lines: Int) -> Int!
  for i in 0..lines
    print("task", id, "line", i)
    if i % 50 == 0
      time.sleep(ms: 1)!
  id

sub main()!
  lines = text.parse_int(os.args()[1])!
  a = talk(1, lines)&
  b = talk(2, lines)&
  c = talk(3, lines)&
  total = >a! + >b! + >c!
  print("done", total)
EOF2

cat >client.py <<'EOF2'
import os, pty, select, socket, stat, subprocess, sys, tempfile, time

mode = sys.argv[1]
env = dict(os.environ)
if len(sys.argv) > 2 and sys.argv[2] != '-':
    env['RIG_WORKERS'] = sys.argv[2]
prog = './' + (sys.argv[3] if len(sys.argv) > 3 else 'srv')

def fail(msg):
    print('FAIL: ' + msg)
    sys.exit(1)

def fill_pipe(fd):
    # Through a description of its own, non-blocking, which leaves the
    # child's blocking.
    chunk = b'f' * 4096
    filled = 0
    for size in (4096, 1):
        while True:
            try:
                filled += os.write(fd, chunk[:size])
            except BlockingIOError:
                break
    return filled

def fill_socket(s):
    # Linux: what fits, never blocking. macOS ignores MSG_DONTWAIT, so
    # there, while the socket polls writable, at most its low-water mark
    # at a time, which never blocks. Either leaves the child's
    # description blocking.
    filled = 0
    if sys.platform == 'linux':
        for size in (4096, 1):
            while True:
                try:
                    filled += s.send(b'f' * size, socket.MSG_DONTWAIT)
                except BlockingIOError:
                    break
        return filled
    low = s.getsockopt(socket.SOL_SOCKET, socket.SO_SNDLOWAT)
    p = select.poll()
    p.register(s.fileno(), select.POLLOUT)
    while p.poll(0):
        filled += s.send(b'f' * low)
    return filled

def ask(p):
    port = int(p.stderr.readline())
    c = socket.create_connection(('127.0.0.1', port), timeout=10)
    c.sendall(b'ping')
    try:
        got = c.recv(16)
    except socket.timeout:
        p.kill()
        fail(mode + ': no answer while stdout is full')
    c.close()
    if got != b'pong':
        fail(mode + ': answer %r' % got)

def hear(start):
    # Listen for the program, which connects, sleeps, and then sends;
    # take all it sends.
    l = socket.socket()
    l.bind(('127.0.0.1', 0))
    l.listen(1)
    l.settimeout(10)
    p = start('127.0.0.1:%d' % l.getsockname()[1])
    try:
        c, _ = l.accept()
        c.settimeout(10)
        got = b''
        while True:
            b = c.recv(64)
            if not b:
                break
            got += b
    except socket.timeout:
        p.kill()
        fail(mode + ': nothing sent after the sleep')
    c.close()
    return p, got

def close_stdout():
    os.close(1)

def closed_status(p):
    err = p.stderr.read().decode()
    if p.wait(timeout=10) != 1:
        fail(mode + ': exit status %r' % p.returncode)
    if err.strip().split('\n')[-1] != 'error: stdout: not open for writing':
        fail(mode + ': stderr %r' % err)

def read_all(read):
    # A slow reader: small reads, a pause between.
    out = b''
    while True:
        b = read(512)
        if not b:
            return out
        out += b
        time.sleep(0.0005)

def check_talk(out, lines, what):
    rows = out.decode().split('\n')
    if rows[-1] != '':
        fail(what + ': no newline at the end')
    rows = rows[:-1]
    if rows[-1] != 'done 6':
        fail(what + ': last line %r' % rows[-1])
    want = {1: 0, 2: 0, 3: 0}
    for r in rows[:-1]:
        w = r.split(' ')
        if len(w) != 4 or w[0] != 'task' or w[2] != 'line':
            fail(what + ': line %r' % r)
        t, i = int(w[1]), int(w[3])
        if want[t] != i:
            fail(what + ': task %d line %d after line %d' % (t, i, want[t] - 1))
        want[t] += 1
    if want != {1: lines, 2: lines, 3: lines}:
        fail(what + ': lines %r' % want)

if mode == 'full-pipe':
    d = tempfile.mkdtemp()
    f = os.path.join(d, 'out')
    os.mkfifo(f)
    r = os.open(f, os.O_RDONLY | os.O_NONBLOCK)
    filler = os.open(f, os.O_WRONLY | os.O_NONBLOCK)
    filled = fill_pipe(filler)
    os.close(filler)
    w = os.open(f, os.O_WRONLY)
    p = subprocess.Popen([prog], stdout=w, stderr=subprocess.PIPE, env=env)
    os.close(w)
    ask(p)
    os.set_blocking(r, True)
    out = read_all(lambda n: os.read(r, n))
    if p.wait(timeout=10) != 0:
        fail(mode + ': exit status')
    if out != b'f' * filled + b'before the answer\nafter the answer 4\n':
        fail(mode + ': output %r' % out[filled:])
elif mode == 'full-socket':
    a, b = socket.socketpair()
    filled = fill_socket(b)
    p = subprocess.Popen([prog], stdout=b.fileno(), stderr=subprocess.PIPE, env=env)
    b.close()
    ask(p)
    out = read_all(a.recv)
    if p.wait(timeout=10) != 0:
        fail(mode + ': exit status')
    if out != b'f' * filled + b'before the answer\nafter the answer 4\n':
        fail(mode + ': output %r' % out[filled:])
elif mode == 'nap-pipe':
    d = tempfile.mkdtemp()
    f = os.path.join(d, 'out')
    os.mkfifo(f)
    r = os.open(f, os.O_RDONLY | os.O_NONBLOCK)
    filler = os.open(f, os.O_WRONLY | os.O_NONBLOCK)
    filled = fill_pipe(filler)
    os.close(filler)
    w = os.open(f, os.O_WRONLY)
    p, got = hear(lambda addr: subprocess.Popen(['./nap', addr], stdout=w, env=env))
    os.close(w)
    if got != b'awake':
        fail(mode + ': sent %r' % got)
    os.set_blocking(r, True)
    out = read_all(lambda n: os.read(r, n))
    if p.wait(timeout=10) != 0:
        fail(mode + ': exit status')
    if out != b'f' * filled + b'before the sleep\nafter the sleep\n':
        fail(mode + ': output %r' % out[filled:])
elif mode == 'closed-nap':
    p, got = hear(lambda addr: subprocess.Popen(['./nap', addr], stderr=subprocess.PIPE, env=env, preexec_fn=close_stdout))
    if got != b'awake':
        fail(mode + ': sent %r' % got)
    closed_status(p)
elif mode == 'closed-srv':
    p = subprocess.Popen([prog], stderr=subprocess.PIPE, env=env, preexec_fn=close_stdout)
    ask(p)
    closed_status(p)
elif mode in ('pipe', 'socket', 'tty', 'file', 'null'):
    lines = 3000
    cmd = ['./talk', str(lines)]
    if mode == 'pipe':
        p = subprocess.Popen(cmd, stdout=subprocess.PIPE, env=env)
        out = read_all(p.stdout.read1)
    elif mode == 'socket':
        a, b = socket.socketpair()
        p = subprocess.Popen(cmd, stdout=b.fileno(), env=env)
        b.close()
        out = read_all(a.recv)
    elif mode == 'tty':
        m, s = pty.openpty()
        # No translation of newlines, no echo.
        import termios, tty
        tty.setraw(s)
        p = subprocess.Popen(cmd, stdout=s, env=env)
        os.close(s)
        def read_pty(n):
            try:
                return os.read(m, n)
            except OSError:
                return b''
        out = read_all(read_pty)
    elif mode == 'file':
        with tempfile.TemporaryFile() as t:
            p = subprocess.Popen(cmd, stdout=t, env=env)
            p.wait(timeout=60)
            t.seek(0)
            out = t.read()
    else:
        with open('/dev/null', 'wb') as t:
            p = subprocess.Popen(cmd, stdout=t, env=env)
            p.wait(timeout=60)
        out = None
    if p.wait(timeout=60) != 0:
        fail(mode + ': exit status')
    if out is not None:
        check_talk(out, lines, mode)
else:
    fail('mode ' + mode)
EOF2

for how in debug release; do
    flag=; [[ $how == release ]] && flag=--release
    for p in srv srv1 nap talk; do
        out=$(rig build $flag $p.rig 2>&1); expect_rc $? 0 "$how build $p: $out"
    done
    for workers in 1 4; do
        for m in full-pipe full-socket; do
            out=$(python3 client.py $m $workers 2>&1); expect_rc $? 0 "$how $m, $workers workers: $out"
        done
    done
    for m in full-pipe full-socket; do
        out=$(python3 client.py $m - srv1 2>&1); expect_rc $? 0 "$how $m, no task: $out"
    done
    out=$(python3 client.py nap-pipe 2>&1); expect_rc $? 0 "$how nap-pipe: $out"
    out=$(python3 client.py closed-nap 2>&1); expect_rc $? 0 "$how closed-nap: $out"
    for p in srv srv1; do
        out=$(python3 client.py closed-srv - $p 2>&1); expect_rc $? 0 "$how closed-srv $p: $out"
    done
    for m in pipe socket tty file null; do
        out=$(python3 client.py $m 2>&1); expect_rc $? 0 "$how $m: $out"
    done
done
exit 0
