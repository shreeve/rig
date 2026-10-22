# Usage: split.py <repo> <outdir>
# Parse `git diff -U0` of tracked files, classify each hunk into a group,
# and write, for each group k, the files with groups 1..k applied.
import re, subprocess, sys, os, json
repo, out = sys.argv[1], sys.argv[2]
names=['names','numeric','hoist','dead','fr2','comments']
explicit = {
 'docs/INTERNALS.md': {988:0, 894:5, 917:5},
 'src/emit.zig': {80:0,126:0,459:0,483:0,488:0,2041:0,2058:0,2062:0,2314:0,2439:0,3677:0,3849:0,4398:0,4418:0,4430:0,4433:0,4453:0,4541:0,4738:0,4794:0,
   3794:1,3822:1,3824:1,3832:1, 4112:2,
   84:3,140:3,146:3,871:3,942:3,1284:3,2302:3,2368:3,2417:3,2659:3,2898:3,4513:3,4568:3,4573:3,4604:3,4621:3,4624:3,4642:3,4689:3,4710:3,5079:3,5131:3,
   3359:4,3901:4, 11:5,1076:5,1081:5,3725:5,3753:5,4647:5,4654:5,5307:5,5316:5},
 'src/runtime.zig': {586:0,605:0,647:0,653:0,1589:0,1611:0,1633:0,1737:0, 875:1,878:1,883:1,
   21:3,28:3,40:3,63:3,112:3,631:3,1102:3,1104:3,1124:3,1128:3,1213:3,1341:3},
}
diff = subprocess.run(['git','-C',repo,'diff','-U0'],capture_output=True,text=True).stdout
files = re.split(r'(?=^diff --git )', diff, flags=re.M)
result = {}
report = []
for f in files:
    if not f.strip(): continue
    m = re.search(r'^\+\+\+ w/(.*)$', f, re.M) or re.search(r'^\+\+\+ b/(.*)$', f, re.M)
    path = m.group(1)
    base = subprocess.run(['git','-C',repo,'show','HEAD:'+path],capture_output=True,text=True).stdout.split('\n')
    hunks = []
    for h in re.split(r'(?=^@@ )', f, flags=re.M)[1:]:
        hm = re.match(r'@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@', h)
        old_start = int(hm.group(1)); old_len = int(hm.group(2)) if hm.group(2) is not None else 1
        lines = h.split('\n')[1:]
        minus = [l[1:] for l in lines if l.startswith('-')]
        plus = [l[1:] for l in lines if l.startswith('+')]
        body = '\n'.join(l for l in lines if l.startswith(('-','+')))
        g = explicit[path][old_start]
        hunks.append((old_start, old_len, minus, plus, g))
        report.append((path, old_start, names[g], body[:200]))
    result[path] = (base, hunks)
os.makedirs(out, exist_ok=True)
for k in range(len(names)):
    d = os.path.join(out, str(k)); os.makedirs(d, exist_ok=True)
    for path,(base,hunks) in result.items():
        lines = list(base)
        for (s, n, minus, plus, g) in sorted(hunks, key=lambda h: -h[0]):
            if g > k: continue
            if n == 0:
                idx = s  # insert after line s
                lines[idx:idx] = plus
            else:
                assert lines[s-1:s-1+n] == minus, (path, s)
                lines[s-1:s-1+n] = plus
        p = os.path.join(d, path); os.makedirs(os.path.dirname(p), exist_ok=True)
        open(p,'w').write('\n'.join(lines))
for r in report: print(r[2].ljust(9), r[0], r[1], '|', r[3].replace('\n',' // ')[:160])
