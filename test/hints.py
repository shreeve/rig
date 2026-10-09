#!/usr/bin/env python3
"""test/hints.py RIG FILE [--run EXPECT]: every hint of the rule that a
lend of a place is never a path's base compiles.

For each diagnostic of the rule in FILE's check (a lend as a path's
base, or a written `!` on a slice only read), the hint is applied alone:
its line is replaced by the rewrite, or by the binding and the rewrite
where a temporary is bound first. The rewritten lines must then draw no
error. A diagnostic that gives no rewrite is skipped. With --run, each
rewritten program must also run sanitizer-clean, in debug and with
--release, and print EXPECT. `./test/run` runs it on every reject test
that has such a diagnostic. Exits 1, listing each bad hint, if any is.
"""
import os, re, shutil, subprocess, sys, tempfile

LEND = re.compile(r'^(?P<f>.+?):(?P<l>\d+):(?P<c>\d+): error: `(?P<path>[^`]+)`: write a lend on the whole path, not its base(?P<rest>.*)$')
SLICE = re.compile(r'^(?P<f>.+?):(?P<l>\d+):(?P<c>\d+): error: `[^`]+` here is read, not held: `(?P<path>[^`]+)` only reads the place it reaches\. Write `(?P<fix>[^`]+)`$')
BIND = re.compile(r'bind it to a name first: `(?P<name>\w+) = (?P<made>[^`]+)`, then `(?P<fix>[^`]+)`$')
FIX = re.compile(r'^: `(?P<fix>.+)`$')
ERROR = re.compile(r'^(?P<f>.+?):(?P<l>\d+):(?P<c>\d+): error: (?P<m>.*)$')


def check(rig, path):
    r = subprocess.run([rig, 'check', path], capture_output=True, text=True, stdin=subprocess.DEVNULL)
    return r.returncode, r.stderr


def hints(rig, path):
    _, err = check(rig, path)
    base = os.path.basename(path)
    for line in err.splitlines():
        m = LEND.match(line)
        if m and os.path.basename(m.group('f')) == base:
            rest = m.group('rest')
            b = BIND.search(rest)
            f = FIX.match(rest)
            if b:
                yield int(m.group('l')), 'bind', (b.group('name'), b.group('made'), b.group('fix'))
            elif f:
                yield int(m.group('l')), 'line', f.group('fix')
            continue
        m = SLICE.match(line)
        if m and os.path.basename(m.group('f')) == base:
            yield int(m.group('l')), 'path', (m.group('path'), m.group('fix'))


def apply(lines, at, kind, fix):
    lines = list(lines)
    text = lines[at - 1]
    indent = text[:len(text) - len(text.lstrip())]
    if kind == 'line':
        lines[at - 1] = indent + fix
        return lines, [at]
    if kind == 'bind':
        name, made, f = fix
        lines[at - 1:at] = [indent + f'{name} = {made}', indent + f]
        return lines, [at, at + 1]
    orig, f = fix
    if orig not in text:
        return None, []
    lines[at - 1] = text.replace(orig, f, 1)
    return lines, [at]


def main():
    args = sys.argv[1:]
    rig, path = args[0], args[1]
    expect = None
    if len(args) > 3 and args[2] == '--run':
        expect = args[3].encode().decode('unicode_escape')
    src = open(path).read().split('\n')
    bad = []
    count = 0
    work = tempfile.mkdtemp(prefix='rig-hints-')
    try:
        # A multi-module test's directory comes along, for the modules it
        # uses; any other test stands alone.
        home = os.path.join(work, 'p')
        if os.path.basename(path) == 'main.rig':
            shutil.copytree(os.path.dirname(os.path.abspath(path)), home, ignore=shutil.ignore_patterns('.zig-cache'))
        else:
            os.makedirs(home)
        target = os.path.join(home, os.path.basename(path))
        _, err0 = check(rig, path)
        before = {}
        for m in map(ERROR.match, err0.splitlines()):
            if m and os.path.basename(m.group('f')) == os.path.basename(path):
                before.setdefault(int(m.group('l')), set()).add(m.group('m'))
        for at, kind, fix in hints(rig, path):
            count += 1
            lines, rows = apply(src, at, kind, fix)
            if lines is None:
                bad.append(f'{path}:{at}: the hint cannot be applied: {fix}')
                continue
            with open(target, 'w') as out:
                out.write('\n'.join(lines))
            _, err = check(rig, target)
            # An error the program draws at that line without the lend,
            # which it drew there with it too, is its own, not the hint's.
            left = [m.group('m') for m in map(ERROR.match, err.splitlines()) if m and int(m.group('l')) in rows and os.path.basename(m.group('f')) == os.path.basename(target) and 'never read' not in m.group('m') and m.group('m') not in before.get(at, ())]
            if left:
                bad.append(f'{path}:{at}: the hint `{fix if kind != "bind" else fix[2]}` draws: {left[0]}')
                continue
            if expect is not None:
                env = dict(os.environ, RIG_SANITIZE='1')
                for mode in ([], ['--release']):
                    r = subprocess.run([rig, 'run'] + mode + [target], capture_output=True, text=True, env=env, stdin=subprocess.DEVNULL)
                    if r.returncode != 0 or r.stdout != expect:
                        bad.append(f'{path}:{at}: the hint runs {mode or "debug"}: status {r.returncode}, {r.stdout!r}, want {expect!r}: {r.stderr[-300:]}')
                        break
            with open(target, 'w') as out:
                out.write('\n'.join(src))
    finally:
        shutil.rmtree(work, ignore_errors=True)
    for b in bad:
        print(b)
    if count == 0 and expect is not None:
        print(f'{path}: no hint to apply')
        sys.exit(1)
    sys.exit(1 if bad else 0)


main()
