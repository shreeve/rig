import sys, collections
import xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
ids = {}
for e in root.iter():
    i = e.get('id')
    if i: ids[i] = e
def resolve(e):
    r = e.get('ref'); return ids[r] if r else e
target = sys.argv[2]; depth = int(sys.argv[3]) if len(sys.argv) > 3 else 3
chains = collections.Counter(); tot = 0
for row in root.iter('row'):
    for c in row:
        if c.tag == 'tagged-backtrace':
            fr = [resolve(f).get('name') or '?' for f in resolve(c).iter('frame')]
            if fr and target in fr[0]:
                tot += 1
                chains[' <- '.join(x.replace('parser.Parser.','P.').replace('lexer.Scanner.','S.')[:60] for x in fr[1:1+depth])] += 1
print(target, tot)
for k, v in chains.most_common(14): print("%5d %s" % (v, k))
