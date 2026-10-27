#!/usr/bin/env python3
# runtests.py RIG TESTFILE OUTDIR [name-filter]: run each `test` block of a
# .rig.test file with RIG (RIG_STD from env), compare stdout.
import sys, os, re, subprocess, textwrap
rig, tf, out = sys.argv[1:4]
flt = sys.argv[4] if len(sys.argv) > 4 else ''
os.makedirs(out, exist_ok=True)
lines = open(tf).read().split('\n')
i = 0; tests = []
while i < len(lines):
    m = re.match(r'^(test|fail) "([^"]+)", (.*)$', lines[i])
    if not m: i += 1; continue
    kind, name, rest = m.groups(); i += 1
    if rest.startswith("'''"):
        exp = []
        while lines[i].strip() != "'''": exp.append(lines[i]); i += 1
        i += 1
        expected = textwrap.dedent('\n'.join(exp)).strip('\n')
    else:
        expected = rest.strip().strip('"')
    body = []
    while i < len(lines) and (lines[i].startswith('  ') or lines[i] == ''):
        body.append(lines[i]); i += 1
    tests.append((kind, name, expected, textwrap.dedent('\n'.join(body))))
bad = 0
for kind, name, expected, body in tests:
    if flt not in name: continue
    f = os.path.join(out, re.sub(r'\W', '_', name) + '.rig')
    open(f, 'w').write(body + '\n')
    env = dict(os.environ, RIG_OUT_DIR=f[:-4] + '.out')
    p = subprocess.run([rig, 'run', f], capture_output=True, text=True, env=env)
    got = (p.stdout if kind == 'test' else p.stderr).strip('\n')
    ok = (got == expected) if kind == 'test' else (expected in got)
    if not ok:
        bad += 1
        print(f'FAIL {name}\n--- expected\n{expected}\n--- got\n{got}\n{p.stderr[-3000:] if kind=="test" else ""}')
    else:
        print(f'ok   {name}')
print('failures', bad)
