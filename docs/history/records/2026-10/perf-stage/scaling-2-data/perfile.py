#!/usr/bin/env python3
# perfile.py TIMELINE_JSON FILES_DIR: from parse.py's timeline.json, each
# file's check time at 4 checkers (check_source_file's entry to its
# return in the task), median over the runs, with its checker; the
# heaviest files and each checker's sum. FILES_DIR/files.PROJ.txt is
# Trig's --listFilesOnly, in program order.
import json, sys, collections, statistics as st
d = json.load(open(sys.argv[1]))
for proj in ('ts-pattern', 'zod3'):
    names = [l.strip() for l in open(f'{sys.argv[2]}/files.{proj}.txt')]
    per = collections.defaultdict(list); kof = {}
    for r in d[f'{proj} trig4']['files']:
        for k, fl in r.items():
            for f, t in fl: per[f].append(t); kof[f] = k
    tot = collections.Counter({k: 0 for k in set(kof.values())})
    for f, ts in per.items(): tot[kof[f]] += st.median(ts)
    print(f'{proj}: {len(per)} files checked; sum by checker (ms): ' + ', '.join(f'{k} {v * 1e3:.0f}' for k, v in sorted(tot.items())))
    for f, ts in sorted(per.items(), key=lambda x: -st.median(x[1]))[:15]:
        print(f'  checker {kof[f]}  {st.median(ts) * 1e3:6.1f} ms  {names[f] if f < len(names) else f}')
