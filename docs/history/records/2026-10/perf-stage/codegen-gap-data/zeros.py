#!/usr/bin/env python3
"""zeros.py PROJDIR CORE STOP_MIB CMD...: runs CMD pinned to CORE, stops it
(SIGSTOP) once its Rss passes STOP_MIB, and for every anonymous mapping
of at least 1 MiB resident counts through /proc/PID/pagemap and /proc/PID/mem
its present pages, those wholly zero, and its zero bytes. With
--runs, the Table region's runs of present pages (a 64 MiB gap ends one)."""
import sys, subprocess, time, os, signal, struct
runs_ = '--runs' in sys.argv
argv = [a for a in sys.argv[1:] if a != '--runs']
proj, core, stop, cmd = argv[0], argv[1], float(argv[2]), argv[3:]
env = dict(os.environ, RAYON_NUM_THREADS='1')
p = subprocess.Popen(['taskset', '-c', core] + cmd, cwd=proj, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=env)
pid = p.pid
def maps():
    out = []; cur = None
    for l in open(f'/proc/{pid}/smaps'):
        parts = l.split()
        if '-' in parts[0] and len(parts) >= 5 and ':' not in parts[0]:
            a, b = parts[0].split('-'); cur = [int(a,16), int(b,16), 0, parts[5] if len(parts) > 5 else '']; out.append(cur)
        elif parts[0] == 'Rss:': cur[2] = int(parts[1])
    return out
while True:
    if p.poll() is not None: sys.exit('exited before the threshold')
    try: m = maps()
    except Exception: continue
    if sum(x[2] for x in m) / 1024 >= stop:
        os.kill(pid, signal.SIGSTOP); break
    time.sleep(0.003)
m = maps()
print(f'# stopped at Rss {sum(x[2] for x in m)/1024:.1f} MiB')
pm = open(f'/proc/{pid}/pagemap', 'rb'); mem = open(f'/proc/{pid}/mem', 'rb')
PG = 4096; Z = bytes(PG)
T = [0, 0, 0]
for a, b, rss, name in sorted(m, key=lambda x: -x[2]):
    if rss < 1024 or (name and not name.startswith('[')): continue
    pages = zp = zb = 0; runs = []; cur = None; last = None
    pg, end = a // PG, b // PG
    while pg < end:
        n = min(1 << 16, end - pg)
        pm.seek(pg * 8); buf = pm.read(n * 8)
        for i in range(n):
            if struct.unpack_from('<Q', buf, i * 8)[0] >> 63:
                addr = (pg + i) * PG
                try: mem.seek(addr); d = mem.read(PG)
                except OSError: continue
                pages += 1; z = d.count(0); zb += z; zp += d == Z
                if runs_:
                    if cur is None or addr - last > (64 << 20): cur = [addr, 0, 0, 0]; runs.append(cur)
                    cur[1] += 1; cur[2] += z; cur[3] += d == Z; last = addr
        pg += n
    T[0] += pages; T[1] += zp; T[2] += zb
    print(f'{a:#x} {(b-a)/2**20:12.1f} MiB  present {pages*PG/2**20:7.1f} MiB  all-zero pages {zp*PG/2**20:6.1f} MiB  zero bytes {100*zb/max(1,pages*PG):5.1f}%  {name}')
    if runs_ and (b - a) > (16 << 30) and (b - a) < (60 << 30):
        for base, n, z, zpg in runs:
            if n * PG >= (256 << 10):
                print(f'    +{(base-a)/2**30:7.2f} GiB  {n*PG/2**20:7.2f} MiB  all-zero pages {zpg*PG/2**20:6.2f} MiB  zero bytes {100*z/(n*PG):5.1f}%')
print(f'# anonymous: present {T[0]*PG/2**20:.1f} MiB, all-zero pages {T[1]*PG/2**20:.1f} MiB, zero bytes {100*T[2]/max(1,T[0]*PG):.1f}%')
os.kill(pid, signal.SIGKILL)
