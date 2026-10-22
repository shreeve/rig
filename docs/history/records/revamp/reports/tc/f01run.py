#!/usr/bin/env python3
"""Rerun the fuzz cases that failed (ctx_split + int) with the dev rig; print outcomes."""
import json, subprocess, os, sys, concurrent.futures as cf
T = '/private/tmp/claude-501/-Users-shreeve-Data-Code-rig/cd00b9f1-8a48-4d11-9781-761746a24702/scratchpad'
RIG = T + '/tc/dev/bin/rig'
cases = []
for area in (sys.argv[2].split(',') if len(sys.argv) > 2 else ['ctx_split', 'int']):
    base = f'{T}/audit-fuzz/c/{area}'
    for l in open(base + '/results.jsonl'):
        r = json.loads(l)
        if r['outcome'] != 'ok' or '--all' in sys.argv:
            cases.append(f"{base}/{r['id']}")
def run(d):
    exp = json.load(open(d + '/expect.json'))
    env = dict(os.environ, RIG_OUT_DIR=T + '/tc/out/' + os.path.basename(d))
    c = subprocess.run([RIG, 'check', d + '/main.rig'], capture_output=True, text=True, env=env)
    if c.returncode != 0:
        return d, 'REJECT', c.stderr.splitlines()[0] if c.stderr else ''
    p = subprocess.run([RIG, 'run', d + '/main.rig'], capture_output=True, text=True, env=env)
    if p.returncode != 0:
        return d, 'FAIL', (p.stderr.strip().splitlines() or [''])[0][:200]
    if exp.get('kind') == 'out' and p.stdout != exp['out']:
        return d, 'WRONG', f"{p.stdout!r} != {exp['out']!r}"
    return d, 'ok', ''
with cf.ThreadPoolExecutor(4) as ex:
    res = list(ex.map(run, cases))
from collections import Counter
print(Counter(r[1] for r in res))
for d, o, m in res:
    if o != 'ok': print(o, d.split('/c/')[1], m)
