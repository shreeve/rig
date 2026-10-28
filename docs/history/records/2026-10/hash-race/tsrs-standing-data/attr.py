#!/usr/bin/env python3
"""attr.py BIN IPS [TSV]: IPS holds one sampled instruction address per line
(perf script -F ip). Each address is symbolized with its inline chain
(llvm-symbolizer); prints shares by the innermost frame's file, by the
innermost (file, function), and by the outermost function. TSV, if named, gets every
(count, innermost file, innermost function, outermost function)."""
import sys, subprocess, collections
bin_, ips = sys.argv[1], sys.argv[2]
cnt = collections.Counter(l.strip() for l in open(ips) if l.strip())
tot = sum(cnt.values())
addrs = sorted(cnt)
p = subprocess.run(['/usr/lib/llvm-22/bin/llvm-symbolizer', f'--obj={bin_}', '--inlines', '--functions=linkage', '--demangle'],
                   input='\n'.join('0x' + a for a in addrs) + '\n', capture_output=True, text=True)
blocks = p.stdout.strip('\n').split('\n\n')
assert len(blocks) == len(addrs), (len(blocks), len(addrs))
by_file = collections.Counter(); by_fn = collections.Counter(); by_outer = collections.Counter(); by_pair = collections.Counter()
for a, b in zip(addrs, blocks):
    ls = b.split('\n')
    frames = [(ls[i], ls[i + 1]) for i in range(0, len(ls) - 1, 2)]
    fn, loc = frames[0]
    f = loc.rsplit(':', 2)[0].split('/')[-1]
    line = loc.rsplit(':', 2)[1] if loc.count(':') >= 2 else '0'
    outer = frames[-1][0]
    n = cnt[a]
    by_file[f] += n; by_fn[(f, fn)] += n; by_outer[outer] += n; by_pair[(f, fn, outer)] += n
def show(title, c, k=40):
    print(f'\n## {title} (of {tot} samples)')
    for key, n in c.most_common(k):
        print(f'{100 * n / tot:6.2f}%  {key if isinstance(key, str) else "  ".join(key)}')
if len(sys.argv) > 3:
    with open(sys.argv[3], 'w') as out:
        for (f, fn, outer), n in by_pair.most_common():
            out.write(f'{n}\t{f}\t{fn}\t{outer}\n')
show('innermost file', by_file, 60)
show('innermost function', by_fn, 80)
show('outermost function (the symbol perf names)', by_outer, 40)
show('innermost function within outermost', by_pair, 60)
