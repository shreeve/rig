#!/usr/bin/env python3
# usage: bench.py ROUNDS INPUT|- name=cmd... ; interleaved, prints min wall, min cpu, max rss
import os, sys, time, shlex
rounds = int(sys.argv[1]); inp = sys.argv[2]; arms = [a.split('=', 1) for a in sys.argv[3:]]
res = {n: [] for n, _ in arms}
for r in range(rounds):
    for n, c in arms:
        args = shlex.split(c)
        fin = os.open(inp if inp != '-' else '/dev/null', os.O_RDONLY)
        fout = os.open('/dev/null', os.O_WRONLY)
        t = time.perf_counter()
        pid = os.fork()
        if pid == 0:
            os.dup2(fin, 0); os.dup2(fout, 1)
            os.execvp(args[0], args)
        _, st, ru = os.wait4(pid, 0)
        dt = time.perf_counter() - t
        os.close(fin); os.close(fout)
        res[n].append((dt, ru.ru_utime + ru.ru_stime, ru.ru_maxrss / 1048576))
print('uptime:', os.popen('uptime').read().strip())
for n, _ in arms:
    v = res[n]; w = sorted(x[0] for x in v)
    print(f"{n:28s} min {w[0]*1000:8.1f} ms  med {w[len(w)//2]*1000:8.1f} ms  cpu {min(x[1] for x in v):7.2f} s  rss {max(x[2] for x in v):6.0f} MB")
