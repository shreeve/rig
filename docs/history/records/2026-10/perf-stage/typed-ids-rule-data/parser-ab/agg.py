import sys, collections
import xml.etree.ElementTree as ET
# Aggregate xctrace time-profile: self and inclusive by symbol.
tree = ET.parse(sys.argv[1]); root = tree.getroot()
ids = {}
def resolve(e):
    r = e.get('ref')
    return ids[r] if r else e
selfc = collections.Counter(); incl = collections.Counter(); callers = collections.defaultdict(collections.Counter)
total = 0
for e in root.iter():
    i = e.get('id')
    if i: ids[i] = e
for row in root.iter('row'):
    bt = None
    for c in row:
        if c.tag in ('backtrace','tagged-backtrace'):
            bt = resolve(c)
    if bt is None: continue
    frames = []
    for f in bt.iter('frame'):
        f = resolve(f)
        frames.append(f.get('name') or '?')
    if not frames: continue
    total += 1
    selfc[frames[0]] += 1
    if len(frames) > 1: callers[frames[0]][frames[1]] += 1
    for n in set(frames): incl[n] += 1
n = int(sys.argv[2]) if len(sys.argv) > 2 else 50
print("total samples", total)
print("--- self")
for k, v in selfc.most_common(n):
    print("%6.2f%% %s" % (100.0*v/total, k[:150]))
print("--- inclusive")
for k, v in incl.most_common(n):
    print("%6.2f%% %s" % (100.0*v/total, k[:150]))
if len(sys.argv) > 3:
    for name in sys.argv[3:]:
        for k in selfc:
            if name in k:
                print("callers of", k[:100], callers[k].most_common(8))
