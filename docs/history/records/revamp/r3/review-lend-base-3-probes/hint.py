#!/usr/bin/env python3
"""hint.py RIG FILE...: apply each lend-base hint alone; report every error the rewritten program draws anywhere (lend-base errors at other lines excepted), and if none, run it sanitized in debug."""
import os, re, subprocess, sys, tempfile
LEND = re.compile(r'^(?P<f>.+?):(?P<l>\d+):(?P<c>\d+): error: `(?P<path>[^`]+)`: write a lend on the whole path, not its base(?P<rest>.*)$')
BIND = re.compile(r'bind it to a name first: `(?P<name>\w+) = (?P<made>[^`]+)`, then `(?P<fix>[^`]+)`$')
FIX = re.compile(r'^: `(?P<fix>.+)`$')
ERR = re.compile(r'^(?P<f>.+?):(?P<l>\d+):(?P<c>\d+): error: (?P<m>.*)$')
rig = sys.argv[1]
def chk(p):
    r = subprocess.run([rig, 'check', p], capture_output=True, text=True)
    return r.returncode, r.stderr
for path in sys.argv[2:]:
    src = open(path).read().split('\n')
    _, err = chk(path)
    errs0 = [m for m in map(ERR.match, err.splitlines()) if m]
    for m in map(LEND.match, err.splitlines()):
        if not m: continue
        at = int(m.group('l')); rest = m.group('rest')
        lines = list(src); text = lines[at-1]; ind = text[:len(text)-len(text.lstrip())]
        b = BIND.search(rest); f = FIX.match(rest)
        if b: lines[at-1:at] = [ind + f"{b.group('name')} = {b.group('made')}", ind + b.group('fix')]; shown = b.group('fix')
        elif f: lines[at-1] = ind + f.group('fix'); shown = f.group('fix')
        else: print(f'{path}:{at}: NOHINT {m.group("path")}'); continue
        d = tempfile.mkdtemp(prefix='h3-'); t = os.path.join(d, os.path.basename(path))
        open(t,'w').write('\n'.join(lines))
        rc, e = chk(t)
        es = [x for x in map(ERR.match, e.splitlines()) if x and 'write a lend on the whole path' not in x.group('m') and 'never read' not in x.group('m')]
        if es:
            print(f'{path}:{at}: hint `{shown}` -> ' + ' | '.join(f"{x.group('l')}:{x.group('m')[:110]}" for x in es[:3]))
        elif rc == 0:
            r = subprocess.run([rig, 'run', t], capture_output=True, text=True, env=dict(os.environ, RIG_SANITIZE='1'))
            print(f'{path}:{at}: hint `{shown}` OK run rc={r.returncode} out={r.stdout.strip()[:80]!r} {r.stderr.strip()[-150:] if r.returncode else ""}')
        else:
            print(f'{path}:{at}: hint `{shown}` -> other lend-base errors remain')
