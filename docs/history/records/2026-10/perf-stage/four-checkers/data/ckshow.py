import sys, collections
names = {0:'iwa calls',1:'iwa ret: no mapper',2:'iwa ret: no type vars',3:'iwa active-cache hit',4:'iwa miss, new mapper (push)',5:'iwa miss, active mapper',6:'find_active_mapper steps',7:'iwa alias key built',8:'cache size at put (sum)',9:'puts into cache >=16',10:'entries cleared at pop (sum)',11:'pops of cache >16',12:'active depth at lookup (sum)',
20:'mapper_map calls',21:'map Simple',22:'map Array',23:'map ArrayToSingle',24:'map Deferred',25:'map Function',26:'map Merged',27:'map Composite',28:'map Inference',29:'Array sources (sum)',
30:'worker: type param',31:'worker: reference',32:'worker: reference unchanged',33:'worker: reverse mapped',34:'worker: object inst',35:'worker: union/intersection',36:'worker: union unchanged',37:'worker: index',38:'worker: indexed access',41:'worker: conditional',42:'worker: substitution',43:'worker: other object',
44:'object inst calls',45:'object inst: no type params',46:'object inst hit',47:'object inst miss',49:'object inst type params (sum)',50:'instantiate_types calls',51:'instantiate_types elements (sum)',52:'conditional inst lookups',53:'conditional inst hits',54:'type reference lookups',55:'type reference hits',
90:'instantiations map size',91:'has_instantiations size',92:'types',93:'instantiation count'}
cols = []
for f in sys.argv[1:]:
    d = collections.defaultdict(lambda: collections.Counter())
    for l in open(f):
        if l.startswith('CK0 '):
            _, k, i, v = l.split(); d[int(k)][int(i)] += int(v)
    cols.append(d)
idx = sorted(set(i for d in cols for c in d.values() for i in c))
hdr = []
for f, d in zip(sys.argv[1:], cols):
    for k in sorted(d): hdr.append(f'{f.split("/")[-1]}:{k}')
print('| counter | ' + ' | '.join(hdr) + ' |')
for i in idx:
    row = []
    for d in cols:
        for k in sorted(d): row.append(f'{d[k][i]:,}')
    print(f'| {i} {names.get(i,"?")} | ' + ' | '.join(row) + ' |')
