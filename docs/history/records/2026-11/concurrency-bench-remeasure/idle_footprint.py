#!/usr/bin/env python3
"""idle_footprint.py N SERVER...: what one idle HTTP connection costs each
of bench/http's built servers, as the kernel counts the process
(`footprint` on macOS, VmRSS plus VmPTE on Linux), page tables included:
the method of test/cli/http_idle_footprint.sh, run on every server alike.

Each SERVER prints its port on stdout and answers `GET /`. 50 connections
warm it, then N more each make one request and stay open; the growth over
them, per connection, is printed with the page tables' share:
`NAME KIB_PER_CONN PAGE_TABLE_KIB_PER_CONN`."""
import os, platform, re, socket, subprocess, sys, time

MAC = platform.system() == "Darwin"


def sample(pid):
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
    s.sendall(b"GET / HTTP/1.1\r\nHost: a\r\n\r\n")
    got = b""
    while not got.endswith(b"Hello, world!"):
        b = s.recv(4096)
        if not b:
            sys.exit("the server closed a connection")
        got += b
    return s


def measure(exe, n):
    p = subprocess.Popen([exe, "127.0.0.1:0"], stdout=subprocess.PIPE, text=True)
    port = int(p.stdout.readline())
    try:
        warm = [request(port) for _ in range(50)]
        time.sleep(0.5)
        before, tb = sample(p.pid)
        held = [request(port) for _ in range(n)]
        time.sleep(0.5)
        after, ta = sample(p.pid)
        for s in warm + held:  # by a reset, which leaves no port in TIME_WAIT
            s.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, b"\x01\x00\x00\x00\x00\x00\x00\x00")
            s.close()
        return (after - before) / n / 1024, (ta - tb) / n / 1024
    finally:
        p.kill()
        p.wait()


def main():
    n = int(sys.argv[1])
    for exe in sys.argv[2:]:
        per, tables = measure(exe, n)
        print("%s %.1f %.2f" % (os.path.basename(exe), per, tables), flush=True)
        time.sleep(1)


main()
