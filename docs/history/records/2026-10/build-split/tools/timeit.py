#!/usr/bin/env python3
"""timeit.py ROUNDS OUT.json NAME=BINARY...: time Trig binaries on ts-pattern
and zod3, interleaved, the order rotated each round. Each run is
`BINARY -p tsconfig.trig.json --noEmit` in the project's directory, under
/usr/bin/time -l (instructions retired, peak RSS); wall time is measured
here. Every run's stdout must equal the first binary's."""
import json, os, re, subprocess, sys, time

ROUNDS, OUT = int(sys.argv[1]), sys.argv[2]
BINS = [a.split('=', 1) for a in sys.argv[3:]]
PROJ = os.path.expanduser('~/Data/Code/trig/misc/projects')
PROJECTS = ['ts-pattern', 'zod3']

def run(binary, project):
    t0 = time.perf_counter()
    p = subprocess.run(['/usr/bin/time', '-l', binary, '-p', 'tsconfig.trig.json', '--noEmit'],
                       cwd=os.path.join(PROJ, project), capture_output=True)
    wall = time.perf_counter() - t0
    err = p.stderr.decode()
    ins = int(re.search(r'(\d+)\s+instructions retired', err).group(1))
    rss = int(re.search(r'(\d+)\s+maximum resident set size', err).group(1))
    return wall, ins, rss, p.stdout, p.returncode

data = {proj: {name: [] for name, _ in BINS} for proj in PROJECTS}
want = {}
for r in range(ROUNDS):
    for proj in PROJECTS:
        order = BINS[r % len(BINS):] + BINS[:r % len(BINS)]
        for name, b in order:
            wall, ins, rss, out, code = run(b, proj)
            key = (out, code)
            if proj not in want:
                want[proj] = key
            if key != want[proj]:
                sys.exit(f'{name} on {proj}: output differs (exit {code})')
            data[proj][name].append(dict(wall=wall, ins=ins, rss=rss))
    print(f'round {r + 1}/{ROUNDS}', file=sys.stderr)
json.dump(data, open(OUT, 'w'), indent=1)
for proj in PROJECTS:
    print(proj)
    base = None
    for name, _ in BINS:
        xs = data[proj][name]
        walls = sorted(x['wall'] for x in xs)
        fastest, median = walls[0], walls[len(walls) // 2]
        ins = min(x['ins'] for x in xs)
        rss = max(x['rss'] for x in xs)
        if base is None:
            base = (fastest, median, ins)
        print(f'  {name:10s} fastest {fastest * 1000:8.1f} ms  median {median * 1000:8.1f} ms  '
              f'ins {ins / 1e9:7.3f} G  rss {rss / 1e6:6.0f} MB  '
              f'fastest/base {fastest / base[0]:.3f}  median/base {median / base[1]:.3f}  ins/base {ins / base[2]:.3f}')
