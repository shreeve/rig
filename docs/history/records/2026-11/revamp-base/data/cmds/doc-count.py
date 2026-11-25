#!/usr/bin/env python3
"""doc-count.py: the doc examples test/rig.rip runs (docFiles: the .md files directly in the root, docs/, docs/learn,
docs/launch, docs/design, docs/internals, examples and test), counted by contract (the first word after ```rig)."""
import os, re, collections
root = os.getcwd(); C = collections.Counter(); files = 0
for d in ['', 'docs', 'docs/learn', 'docs/launch', 'docs/design', 'docs/internals', 'examples', 'test']:
    p = os.path.join(root, d)
    if not os.path.isdir(p): continue
    for f in sorted(os.listdir(p)):
        if not f.endswith('.md'): continue
        t = open(os.path.join(p, f), encoding='utf8').read()
        blocks = re.findall(r'^```rig([ \t][^\n]*)?$', t, re.M)
        if not blocks: continue
        files += 1
        for b in blocks:
            w = (b or '').split()
            C['file=' if w and w[0].startswith('file=') else (w[0] if w else 'plain')] += 1
print("docs with examples:", files); print("examples:", sum(C.values()))
for k, v in sorted(C.items()): print(" ", k, v)
