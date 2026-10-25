#!/usr/bin/env python3
# mactime.py ROUNDS OUT VARIANT=BIN...: interleaved wall time of each binary on ts-pattern and zod3, fastest of N.
import sys, subprocess, time, hashlib, os
rounds = int(sys.argv[1]); out = sys.argv[2]; vs = [a.split('=', 1) for a in sys.argv[3:]]
P = os.path.expanduser('~/Data/Code/trig/misc/projects')
best = {}; dig = {}
for r in range(rounds):
    for p in ['tiny-invariant', 'zod3', 'ts-pattern']:
        order = vs[r % len(vs):] + vs[:r % len(vs)]
        for name, b in order:
            t0 = time.perf_counter()
            res = subprocess.run([b, '-p', 'tsconfig.trig.json', '--noEmit', '--singleThreaded'], cwd=f'{P}/{p}', capture_output=True)
            dt = time.perf_counter() - t0
            dig.setdefault((p, name), set()).add(hashlib.md5(res.stdout + res.stderr).hexdigest())
            best[(p, name)] = min(best.get((p, name), 9e9), dt)
            open(out, 'a').write(f'{r}\t{p}\t{name}\t{dt:.4f}\n')
for p in ['tiny-invariant', 'zod3', 'ts-pattern']:
    b0 = best[(p, vs[0][0])]
    print(p, '  '.join(f'{n} {best[(p, n)]*1000:.1f} ms ({100*(best[(p, n)]-b0)/b0:+.2f}%)' for n, _ in vs),
          'outputs same' if all(dig[(p, n)] == dig[(p, vs[0][0])] for n, _ in vs) else 'OUTPUTS DIFFER')
