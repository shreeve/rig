import sys, os, re, collections
sys.path.insert(0, '/Users/shreeve/Data/Code/rig/.git/revamp/r3')
import polish_rewrite as pr
log = sys.argv[1]
def syn_changes(text):
    lines = text.split('\n'); orig = lines[:]
    e = pr.Edits(); pr.add_params(lines, e); pr.rename_builtins(lines, e)
    return lines != orig
cache = {}
def file_changes(p):
    if p not in cache:
        cache[p] = syn_changes(open(p).read()) if os.path.exists(p) else False
    return cache[p]
def std_used(text):
    return re.findall(r'^\s*use\s+std\.(\w+)', text, re.M)
def block_text(prog):
    m = re.match(r'\.equiv-docs/(.+)/L(\d+)/main\.rig', prog)
    name, ln = m.group(1), int(m.group(2))
    md = name.replace('-', '/') + '.md'
    if not os.path.exists(md): md = name + '.md'
    if not os.path.exists(md):  # e.g. test-README
        md = name.replace('-', '/', 1) + '.md'
    L = open(md).read().split('\n')
    i = ln - 1
    j = i + 1
    while L[j] != '```': j += 1
    return '\n'.join(L[i+1:j])
cats = collections.Counter(); other = []
for line in open(log):
    m = re.match(r'^(\S+\.rig): (.*)$', line.strip())
    if not m: continue
    prog, secs = m.group(1), m.group(2).split()
    if prog.startswith('.equiv-docs/'):
        texts = [block_text(prog)]
    elif prog.endswith('main.rig') and prog.startswith('test/'):
        d = os.path.dirname(prog); texts = [open(os.path.join(d, f)).read() for f in os.listdir(d) if f.endswith('.rig')]
    else:
        texts = [open(prog).read()]
    own = any(syn_changes(t) for t in texts)
    stds = {s for t in texts for s in std_used(t)}
    stdc = any(file_changes('std/%s.rig' % s) for s in stds)
    if own: cats['own syntax'] += 1
    elif stdc: cats['uses a rewritten std module'] += 1
    elif secs == ['pkg']: cats['pkg only (runtime.zig comment)'] += 1
    else: cats['other'] += 1; other.append(line.strip())
print(dict(cats))
for o in other[:50]: print('  ', o)
