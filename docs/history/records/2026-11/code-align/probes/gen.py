#!/usr/bin/env python3
"""gen.py K OUT.rig: fork.rig with K never-taken prints at the end of main
(qsort-mac's shift/sK.rig): they only grow main, so they move qsort and
the functions after it."""
import os, sys
k, out = int(sys.argv[1]), sys.argv[2]
src = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "fork.rig")).read().rstrip("\n") + "\n"
for j in range(k):
    src += '  print("pad%d", ok + %d) if t2.elapsed() == 1000\n' % (j, j)
open(out, "w").write(src)
