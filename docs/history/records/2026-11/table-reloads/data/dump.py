#!/usr/bin/env python3
# dump.py DATA COMM BINPATH DELTA [lat]: samples of COMM in BINPATH's text as "fileaddr dataaddr weight", for llvm-symbolizer.
# DELTA = exec segment p_vaddr - p_offset (0 for an EXEC binary mapped at its vaddr: then addresses pass unchanged).
import sys, subprocess, re
data, comm, binp, delta = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4], 16)
mode = sys.argv[5] if len(sys.argv) > 5 else ''
lat = mode in ('lat', 'addr')
fields = {'lat': 'comm,ip,addr,weight', 'addr': 'comm,ip,addr'}.get(mode, 'comm,ip')
p = subprocess.Popen(['perf', 'script', '-i', data, '--show-mmap-events', '-F', fields], stdout=subprocess.PIPE, text=True, errors='replace')
maps = []
mm = re.compile(r'MMAP2? .*\[(0x[0-9a-f]+)\((0x[0-9a-f]+)\) @ (0x[0-9a-f]+|0) .*\]: r-xp (\S+)')
out = sys.stdout; n = 0; skip = 0
for l in p.stdout:
    if 'PERF_RECORD_MMAP' in l:
        m = mm.search(l)
        if m and m.group(4) == binp:
            s, ln, off = int(m.group(1), 16), int(m.group(2), 16), int(m.group(3), 16)
            maps.append((s, s + ln, off))
        continue
    f = l.split()
    if not f or f[0] != comm: skip += 1; continue
    try:
        if mode == 'lat': addr, w, ip = int(f[1], 16), int(f[2]), int(f[3], 16)
        elif mode == 'addr': addr, ip, w = int(f[1], 16), int(f[2], 16), 1
        else: ip = int(f[1], 16); addr = 0; w = 1
    except (ValueError, IndexError): skip += 1; continue
    for s, e, off in maps:
        if s <= ip < e:
            fa = ip - s + off + delta if (s, off) != (0, 0) else ip
            # EXEC binaries: mapping start equals vaddr, so ip - s + off + delta == ip when delta = vaddr - offset
            out.write(f'{fa:x} {addr:x} {w}\n'); n += 1; break
    else: skip += 1
sys.stderr.write(f'{n} samples kept, {skip} skipped, maps {[(hex(a),hex(b),hex(c)) for a,b,c in maps]}\n')
