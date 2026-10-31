#!/usr/bin/env python3
"""rss.py BIN PROJDIR CORE: runs BIN on PROJDIR pinned to CORE, reads
/proc/PID/smaps every 5 ms, and prints the mappings of the snapshot with the
largest total Rss: start, size, Rss, Anonymous, name."""
import sys, subprocess, time, os
bin_, proj, core = sys.argv[1], sys.argv[2], sys.argv[3]
args = sys.argv[4:] or [bin_, '-p', 'tsconfig.trig.json', '--noEmit', '--singleThreaded']
p = subprocess.Popen(['taskset', '-c', core] + args, cwd=proj, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
best = (0, None)
def snap(pid):
    maps = []; cur = None
    with open(f'/proc/{pid}/smaps') as f:
        for l in f:
            parts = l.split()
            if '-' in parts[0] and len(parts) >= 5 and ':' not in parts[0]:
                a, b = parts[0].split('-'); cur = [int(a,16), int(b,16)-int(a,16), 0, 0, parts[5] if len(parts) > 5 else '']; maps.append(cur)
            elif parts[0] == 'Rss:': cur[2] = int(parts[1])
            elif parts[0] == 'Anonymous:': cur[3] = int(parts[1])
    return maps
time.sleep(0.002)
while p.poll() is None:
    try:
        # taskset execs, so the pid is the program's
        m = snap(p.pid)
        tot = sum(x[2] for x in m)
        if tot > best[0]: best = (tot, m)
    except Exception: pass
    time.sleep(0.005)
tot, m = best
print(f'# peak sampled Rss {tot/1024:.1f} MiB')
for a, size, rss, anon, name in sorted(m, key=lambda x: -x[2]):
    if rss >= 256: print(f'{a:#x} {size/1048576:10.1f} MiB  rss {rss/1024:8.1f} MiB  anon {anon/1024:8.1f}  {name}')
