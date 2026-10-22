import re, os, sys, glob
root = sys.argv[1] if len(sys.argv) > 1 else "/Users/shreeve/Data/Code/rig-rv-docs"
os.chdir(root)
files = sorted(set(glob.glob("*.md") + glob.glob("docs/*.md") + glob.glob("examples/*.md") + glob.glob("test/**/*.md", recursive=True)))
def slug(h):
    h = h.strip().lower()
    h = re.sub(r'[^\w\- ]', '', h)
    return h.replace(' ', '-')
anchors = {}
for f in files:
    p = os.path.join(root, f); seen = {}; a = set(); inb = False
    for line in open(p):
        if line.startswith("```"): inb = not inb; continue
        if inb: continue
        m = re.match(r'^(#+)\s+(.*)', line)
        if m:
            s = slug(m.group(2)); n = seen.get(s, 0); seen[s] = n + 1
            a.add(s if n == 0 else f"{s}-{n}")
    anchors[os.path.normpath(p)] = a
bad = 0
for f in files:
    p = os.path.join(root, f); inb = False
    for i, line in enumerate(open(p), 1):
        if line.startswith("```"): inb = not inb; continue
        if inb: continue
        for m in re.finditer(r'\]\(([^)\s]+)\)', re.sub(r'`[^`]*`', '', line)):
            t = m.group(1)
            if t.startswith("http") or t.startswith("mailto:"): continue
            path, _, frag = t.partition("#")
            tp = os.path.normpath(os.path.join(os.path.dirname(p), path)) if path else os.path.normpath(p)
            if not os.path.exists(tp):
                print(f"{f}:{i}: missing file {t}"); bad += 1; continue
            if frag and tp.endswith(".md"):
                if frag not in anchors.get(tp, set()):
                    print(f"{f}:{i}: missing anchor {t}"); bad += 1
print("files:", len(files), "bad:", bad)
