"""Count trait, generic, lifetime and ownership forms in the Rust originals of the Rig ports.
Pattern matches over code with comments and string contents removed, not parses."""
import os, re, collections

R = os.path.expanduser('~/Data/Code/rig')
CORPORA = [
    ('uucore', [f'{R}/compare/rust/coreutils/src/uucore/src']),
    ('ring', [f'{R}/misc/ring/src']),
    ('tokio', [f'{R}/misc/tokio/tokio/src']),
    ('tokio-util+stream', [f'{R}/misc/tokio/tokio-util/src', f'{R}/misc/tokio/tokio-stream/src']),
]

FEATURES = [
    ('trait declaration', r'\btrait\s+[A-Z]'),
    ('impl Trait for Type', r'\bimpl\b(?:<[^{]*?>)?\s+[\w:<>, \']+\s+for\s+'),
    ('derive(...) items', None),  # counted specially
    ('generic fn/struct/enum/impl <T>', r'\b(?:fn\s+\w+|struct\s+\w+|enum\s+\w+|impl)\s*<\s*(?:\'\w+\s*,\s*)*[A-Z]'),
    ('where clause', r'\bwhere\b'),
    ('trait bound T: Trait', r'[<,]\s*[A-Z]\w*\s*:\s*[?\'A-Z]'),
    ('impl Trait (arg/return)', r'(?:->|:|\()\s*&?(?:mut\s+)?impl\s+'),
    ('dyn Trait', r'\bdyn\s+'),
    ('lifetime \'a', r"'(?!static\b)[a-z_]\w*\b(?!')"),
    ('blanket impl<T> Trait for T', r'\bimpl\s*<[^>]*>\s+[\w:]+(?:<[^{]*>)?\s+for\s+[A-Z]\b'),
    ('associated type', r'^\s*type\s+[A-Z]\w*\s*(?:=|:|;)'),
    ('Send / Sync bound or impl', r'\b(?:Send|Sync)\b'),
    ('Pin< / Future / poll', r'\bPin<|\bFuture\b|\bfn\s+poll'),
    ('PhantomData', r'\bPhantomData\b'),
    ('macro_rules!', r'\bmacro_rules!'),
    ('#[cfg(...)]', r'#\[cfg\('),
    ('unsafe impl', r'\bunsafe\s+impl\b'),
    ('.clone()', r'\.clone\(\)'),
    ('Rc / Arc', r'\b(?:Rc|Arc)\b'),
    ('Box<', r'\bBox<'),
    ('Mutex / RwLock / RefCell / Cell', r'\b(?:Mutex|RwLock|RefCell|Cell)\b'),
    ('&mut', r'&mut\b'),
    ('unsafe', r'\bunsafe\b'),
    ('async / .await', r'\basync\b|\.await\b'),
]

def strip(line):
    out, i, q = [], 0, False
    while i < len(line):
        ch = line[i]
        if q:
            if ch == '\\':
                i += 2
                continue
            if ch == '"':
                q = False
                out.append(ch)
        elif ch == '"':
            q = True
            out.append(ch)
        elif line.startswith('//', i):
            break
        else:
            out.append(ch)
        i += 1
    return ''.join(out)

counts = collections.defaultdict(collections.Counter)
lines = collections.Counter()
rx = [(n, re.compile(p) if p else None) for n, p in FEATURES]
derive = re.compile(r'#\[derive\(([^)]*)\)')
for name, roots in CORPORA:
    for root in roots:
        for d, dirs, fs in os.walk(root):
            dirs[:] = [x for x in dirs if x not in ('target', '.git')]
            for f in fs:
                if not f.endswith('.rs'):
                    continue
                incomment = False
                for raw in open(os.path.join(d, f), encoding='utf-8', errors='replace'):
                    s = raw.strip()
                    if incomment:
                        if '*/' in s:
                            incomment = False
                        continue
                    if s.startswith('/*'):
                        incomment = '*/' not in s
                        continue
                    code = strip(raw.rstrip('\n'))
                    if not code.strip():
                        continue
                    lines[name] += 1
                    for n, r in rx:
                        if r is None:
                            for m in derive.finditer(code):
                                counts[n][name] += len([x for x in m.group(1).split(',') if x.strip()])
                        else:
                            counts[n][name] += len(r.findall(code))

names = [n for n, _ in CORPORA]
print('| Rust form | ' + ' | '.join(names) + ' | per 1,000 lines |')
print('|---|' + '---:|' * (len(names) + 1))
total = sum(lines.values())
print('| code lines | ' + ' | '.join(f'{lines[n]:,}' for n in names) + f' | {total:,} |')
for n, _ in FEATURES:
    t = sum(counts[n].values())
    print(f'| {n} | ' + ' | '.join(f'{counts[n][c]:,}' if counts[n][c] else '·' for c in names) + f' | {1000 * t / total:.1f} |')
