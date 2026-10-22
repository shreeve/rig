#!/usr/bin/env python3
"""Mark every change to a shared Cell or Signal: `c.set(5)` -> `!c.set(5)`.

    [BASE_TREE=DIR] rewrite.py NEW_RIG OLD_RIG [-j N] [--md] [PATH...]

Re-runnable. It lets the compiler find each site: a diagnostic NEW_RIG
draws that OLD_RIG did not draw (same line text and message), of the
forms the rule makes, is fixed in place, and the file is checked again
until nothing new remains:

  method `m` needs its receiver lent to write; write `HINT`
      the receiver path gets `!` (statement), or `(!path).m(...)` when
      the call's value is used
  method `m` needs its receiver lent to write; a read view cannot ...
      the enclosing signature's `?name` / `?self` becomes `!name`
  an argument `x` where a `!Cell[T]` goes
      the argument becomes `!x`
  write `(!c)[i] = e`: changing a shared Cell is marked with `!`
      the assigned element of a Cell's Vec gets the mark

BASE_TREE is a pristine checkout (git archive) of the commit before the
rewrite: the diagnostics OLD_RIG draws there are the program's own, and
are left alone. Without it OLD_RIG checks the files as they stand.

PATH defaults to every tracked .rig under test/ examples/ std/ (and
with --md, the ```rig blocks of the Markdown docs). Sites it cannot fix
are listed on stderr for hand edits. Run from the repository root.
"""
import concurrent.futures as cf
import os
import re
import subprocess
import sys
import tempfile

ROOT = os.getcwd()
DIAG = re.compile(r'^(.*?):(\d+):(\d+): error: (.*)$')


BASE = os.environ.get('BASE_TREE')


def check(rig, path, cwd=None):
    p = subprocess.run([rig, 'check', path], capture_output=True, text=True, cwd=cwd or ROOT)
    out = []
    for line in p.stderr.splitlines() + p.stdout.splitlines():
        m = DIAG.match(line)
        if m:
            out.append((m.group(1), int(m.group(2)), int(m.group(3)), m.group(4)))
    return out


def key(path, lines, ln, msg):
    text = lines[ln - 1].strip() if 0 < ln <= len(lines) else ''
    return (os.path.basename(path), re.sub(r'[!()]', '', text), re.sub(r'[!()]', '', msg))


def receiver_start(line, dot):
    """Index where the receiver path ending before line[dot] ('.') starts."""
    i = dot
    while i > 0:
        c = line[i - 1]
        if c in ')]':
            close, open_ = c, '(' if c == ')' else '['
            depth = 0
            while i > 0:
                i -= 1
                if line[i] == close:
                    depth += 1
                elif line[i] == open_:
                    depth -= 1
                    if depth == 0:
                        break
        elif c.isalnum() or c in '_.':
            i -= 1
        else:
            break
    return i


def call_end(line, open_paren):
    depth = 0
    for i in range(open_paren, len(line)):
        if line[i] == '(':
            depth += 1
        elif line[i] == ')':
            depth -= 1
            if depth == 0:
                return i + 1
    return len(line)


def fix_site(lines, ln, col, msg):
    """Edit lines in place for one diagnostic; False if it is not a form we fix."""
    if not 0 < ln <= len(lines):
        return False
    line = lines[ln - 1]
    m = re.match(r'method `(\w+)` needs its receiver lent to write; (?:write `.*|a read view cannot become a write view)$', msg)
    if m:
        method = m.group(1)
        view = 'a read view' in msg
        dot = col - 2
        if dot < 0 or line[dot] != '.' or not line[col - 1:].startswith(method):
            return False
        start = receiver_start(line, dot)
        recv = line[start:dot]
        if view:
            root = re.match(r'\w+', recv)
            return bool(root) and fix_signature(lines, ln, root.group(0))
        open_paren = col - 1 + len(method)
        end = call_end(line, open_paren) if open_paren < len(line) and line[open_paren] == '(' else open_paren
        stmt = line[:start].strip() == '' and line[end:].split('#')[0].strip() == ''
        void = method in ('set', 'push', 'clear', 'subscribe')
        if stmt or (void and line[:start].rstrip().endswith('|')):
            lines[ln - 1] = line[:start] + '!' + line[start:]
        else:
            lines[ln - 1] = line[:start] + '(!' + recv + ')' + line[dot:]
        return True
    m = re.match(r'(?:write|.*? changes its receiver, a temporary no name holds; add `!`:) `(.*?)`(?::| *$)', msg)
    if m and ('the call writes' in msg or 'a temporary no name holds' in msg or 'a write call whose value is used' in msg):
        return fix_hint(lines, ln, col, m.group(1))
    m = re.match(r'type mismatch: expected `!(.*)`, got `[?*]', msg)
    if m:
        i = col - 1
        if line[i] == '?':
            lines[ln - 1] = line[:i] + '!' + line[i + 1:]
        elif line[i] != '!':
            lines[ln - 1] = line[:i] + '!' + line[i:]
        else:
            return False
        return True
    m = re.search(r'(?:bind it with|match with) `([^`]*)`$', msg)
    if m and msg.startswith('cannot lend to write through a read view'):
        return fix_header(lines, ln, m.group(1))
    m = re.match(r'cannot lend `(.*)` to write: it may be .*; lend each branch: `(!\(.*)`$', msg)
    if m:
        return fix_branch(lines, ln, col, m.group(1), m.group(2))
    m = re.match(r'write `\(!(.*)\)\[i\] = e`: changing a shared Cell is marked', msg)
    if m:
        cell = m.group(1)
        i = col - 1
        if line.startswith(cell + '[', i):
            lines[ln - 1] = line[:i] + '(!' + cell + ')' + line[i + len(cell):]
            return True
        return False
    if msg.startswith('cannot lend to write through a read view'):
        root = re.match(r'\w+', line[col - 1:])
        return bool(root) and fix_signature(lines, ln, root.group(0))
    return False


def fix_header(lines, ln, hint):
    """The header above line ln that `hint` (`if !o as c`) writes: re-sigil it."""
    pat = re.compile(r'(?<![\w])' + re.escape(hint).replace('\\!', '[?!]?').replace('!', '[?!]?'))
    for i in range(ln - 1, max(ln - 40, -1), -1):
        m = pat.search(lines[i])
        if m and m.group(0) != hint:
            lines[i] = lines[i][:m.start()] + hint + lines[i][m.end():]
            return True
        if m:
            return False
    return False


def fix_branch(lines, ln, col, branch, hint):
    line = lines[ln - 1]
    depth = 0
    for k, ch in enumerate(hint):
        depth += ch == '('
        depth -= ch == ')'
        if depth == 0 and ch == ')':
            break
    suffix = hint[k + 1:]
    old = '!(' + branch + ')' + suffix
    i = col - 3
    if i < 0 or not line.startswith(old, i):
        return False
    lines[ln - 1] = line[:i] + hint + line[i + len(old):]
    return True


def fix_hint(lines, ln, col, hint):
    line = lines[ln - 1]
    i = col - 1
    if hint.startswith('(!'):
        if line[i:i + 1] == '!':
            line = line[:i] + line[i + 1:]
        depth = 0
        for k, ch in enumerate(hint):
            depth += ch == '('
            depth -= ch == ')'
            if depth == 0:
                break
        orig = hint[2:k] + hint[k + 1:]
        if not line.startswith(orig, i):
            return False
        lines[ln - 1] = line[:i] + hint + line[i + len(orig):]
        return True
    if hint.startswith('!') and line.startswith(hint[1:], i):
        lines[ln - 1] = line[:i] + '!' + line[i:]
        return True
    return False


def fix_signature(lines, ln, root):
    indent = len(lines[ln - 1]) - len(lines[ln - 1].lstrip())
    for i in range(ln - 2, -1, -1):
        l = lines[i]
        if not l.strip():
            continue
        ind = len(l) - len(l.lstrip())
        if ind >= indent:
            continue
        if re.match(r'\s*(pub\s+)?(sub|fun|drop|init)\b', l) or re.search(r'\b(sub|fun)\b', l):
            if root == 'self':
                if '?self' in l:
                    lines[i] = l.replace('?self', '!self', 1)
                    return True
            else:
                n = re.sub(r'\b' + re.escape(root) + r': \?', root + ': !', l, count=1)
                if n != l:
                    lines[i] = n
                    return True
            return False
        indent = ind
    return False


def fix_file(args):
    new, old, path = args
    try:
        before = open(path).read()
    except OSError:
        return path, None, []
    if BASE and not os.path.isabs(path) and not os.path.exists(os.path.join(BASE, path)):
        # A test written for the rule (not in the base tree) is left as written.
        return path, False, []
    cache = {}

    def lines_of(p):
        if p not in cache:
            cache[p] = open(p).read().split('\n')
        return cache[p]

    base = set()
    if BASE and not os.path.isabs(path):
        # The old compiler checks the original program, in a pristine tree.
        for (p, ln, c, msg) in check(old, path, BASE):
            try:
                base.add(key(p, open(os.path.join(BASE, p)).read().split('\n'), ln, msg))
            except OSError:
                pass
    else:
        for (p, ln, c, msg) in check(old, path):
            try:
                base.add(key(p, lines_of(p), ln, msg))
            except OSError:
                pass
    touched = set()
    left = []
    for _ in range(60):
        cache.clear()
        diags = check(new, path)
        fresh = []
        for d in diags:
            try:
                if key(d[0], lines_of(d[0]), d[1], d[3]) not in base:
                    fresh.append(d)
            except OSError:
                pass
        if not fresh:
            left = []
            break
        done = False
        for (p, ln, col, msg) in sorted(fresh, key=lambda d: (d[0], -d[1], -d[2])):
            lines = lines_of(p)
            if fix_site(lines, ln, col, msg):
                open(p, 'w').write('\n'.join(lines))
                touched.add(p)
                done = True
                break
        left = fresh
        if not done:
            break
    return path, bool(touched) or open(path).read() != before, left


def tracked(globs):
    out = subprocess.run(['git', 'ls-files'] + globs, capture_output=True, text=True, cwd=ROOT).stdout.split()
    return out


FENCE = re.compile(r'^```rig(?: (\w+))?\s*$')


def fix_md(args):
    new, old, path = args
    text = open(path).read().split('\n')
    i = 0
    changed = False
    unresolved = []
    while i < len(text):
        m = FENCE.match(text[i])
        if not m:
            i += 1
            continue
        j = i + 1
        while not text[j].startswith('```'):
            j += 1
        block = '\n'.join(text[i + 1:j]) + '\n'
        # An example written for the rule (its error asks for the mark) stays.
        marks = 'is marked with `!`' in '\n'.join(text[j + 1:j + 8])
        if not marks and re.search(r'\b(Cell|Signal)\b', block):
            with tempfile.TemporaryDirectory() as d:
                tmp = os.path.join(d, 'x.rig')
                open(tmp, 'w').write(block)
                _, ch, left = fix_file((new, old, tmp))
                if ch:
                    nb = open(tmp).read().rstrip('\n').split('\n')
                    text[i + 1:j] = nb
                    j = i + 1 + len(nb)
                    changed = True
                unresolved += [(f'{path}:{i + 1}', l[1], l[3]) for l in left] if not m.group(1) else []
        i = j + 1
    if changed:
        open(path, 'w').write('\n'.join(text))
    return path, changed, unresolved


def main():
    a = sys.argv[1:]
    new, old = os.path.abspath(a[0]), os.path.abspath(a[1])
    jobs = 8
    md = False
    paths = []
    k = 2
    while k < len(a):
        if a[k] == '-j':
            jobs = int(a[k + 1]); k += 1
        elif a[k] == '--md':
            md = True
        else:
            paths.append(a[k])
        k += 1
    if md:
        files = paths or tracked(['*.md'])
        fn = fix_md
    else:
        files = paths or tracked(['test/*.rig', 'examples/*.rig', 'std/*.rig'])
        files = [f for f in files if '/torture/' not in f and re.search(r'\b(Cell|Signal)\b', open(os.path.join(ROOT, f)).read())]
        fn = fix_file
    changed = 0
    bad = 0
    with cf.ThreadPoolExecutor(jobs) as ex:
        for path, ch, left in ex.map(fn, [(new, old, f) for f in files]):
            changed += bool(ch)
            for l in left:
                bad += 1
                print('UNFIXED', path, l, file=sys.stderr)
    print(f'{changed} files changed, {bad} sites left', file=sys.stderr)


main()
