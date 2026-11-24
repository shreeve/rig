#!/usr/bin/env python3
# measure.py ROUNDS OUT.tsv ARM=BIN ...: c1 (--singleThreaded) runs of each project, --noCheck and full,
# arms interleaved with the order rotating each round, each run under /usr/bin/time -l
# (env -u TRIG_PREBUILT_LIBS BIN --singleThreaded [--noCheck] --noEmit -p CFG, in the project's
# folder). Writes one row per run: round arm project mode wall_s user_s sys_s instructions cycles maxrss stdout_sha.
import hashlib, os, re, subprocess, sys
C = os.path.expanduser('~/Data/Code/trig/misc/corpus')
projects = [('Compiler', C + '/typescript-benchmarking/cases/solutions/Compiler', 'tsconfig.json'),
            ('webpack', C + '/webpack', 'tsconfig.json'),
            ('typeorm', C + '/typeorm/packages/typeorm', 'tsconfig.json'),
            ('Compiler-Unions', C + '/typescript-benchmarking/cases/solutions/Compiler-Unions', 'tsconfig.json')]
rounds = int(sys.argv[1]); out = sys.argv[2]; arms = [a.split('=', 1) for a in sys.argv[3:]]
with open(out, 'w') as o:
    o.write('round\tarm\tproject\tmode\twall\tuser\tsys\tinstructions\tcycles\tmaxrss\tsha\n')
    order = list(arms)
    for r in range(1, rounds + 1):
        for name, d, cfg in projects:
            for mode in os.environ.get('MODES', 'noCheck full').split():
                for a, b in order:
                    cmd = ['/usr/bin/time', '-l', 'env', '-u', 'TRIG_PREBUILT_LIBS', b, '--singleThreaded'] + (['--noCheck'] if mode == 'noCheck' else []) + ['--noEmit', '-p', cfg]
                    p = subprocess.run(cmd, cwd=d, capture_output=True)
                    err = p.stderr.decode(errors='replace')
                    def g(pat):
                        m = re.search(pat, err); return m.group(1) if m else '0'
                    o.write('%d\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' % (r, a, name, mode, g(r'([\d.]+) real'), g(r'([\d.]+) user'), g(r'([\d.]+) sys'),
                            g(r'(\d+)\s+instructions retired'), g(r'(\d+)\s+cycles elapsed'), g(r'(\d+)\s+maximum resident'), hashlib.sha1(p.stdout).hexdigest()[:12]))
                    o.flush()
        order = order[1:] + order[:1]
