# smaps.py SMAPS: anonymous memory by kind of mapping: VMAs, Rss, AnonHugePages, and Rss in VMAs of 2 MiB or less.
import sys, re
vmas = []; cur = None
for line in open(sys.argv[1]):
    m = re.match(r'([0-9a-f]+)-([0-9a-f]+) (\S+) \S+ \S+ \S+\s*(.*)$', line)
    if m:
        cur = {'lo': int(m.group(1), 16), 'hi': int(m.group(2), 16), 'name': m.group(4).strip() or '[anon]', 'Rss': 0, 'AnonHugePages': 0, 'flags': ''}
        vmas.append(cur); continue
    m = re.match(r'(\w+):\s+(\d+) kB', line)
    if m and cur is not None and m.group(1) in ('Rss', 'AnonHugePages'): cur[m.group(1)] = int(m.group(2))
    m = re.match(r'VmFlags:\s*(.*)', line)
    if m and cur is not None: cur['flags'] = m.group(1)
anon = [v for v in vmas if v['name'] == '[anon]']
def s(vs, k): return sum(v[k] for v in vs) / 1024
small = [v for v in anon if v['hi'] - v['lo'] <= 2 << 20]
nh = [v for v in anon if ' nh' in ' ' + v['flags']]
hg = [v for v in anon if ' hg' in ' ' + v['flags']]
print(f"VMAs {len(vmas)} (anon {len(anon)}); anon Rss {s(anon,'Rss'):.1f} MiB, of it huge {s(anon,'AnonHugePages'):.1f} MiB")
print(f"  advised NOHUGEPAGE (nh): {len(nh)} VMAs, Rss {s(nh,'Rss'):.1f} MiB")
print(f"  advised HUGEPAGE (hg): {len(hg)} VMAs, Rss {s(hg,'Rss'):.1f} MiB, huge {s(hg,'AnonHugePages'):.1f} MiB")
print(f"  VMAs of 2 MiB or less: {len(small)}, Rss {s(small,'Rss'):.1f} MiB")
