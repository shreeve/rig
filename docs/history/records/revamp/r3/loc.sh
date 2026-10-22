#!/bin/bash
# loc.sh: tracked lines split into source, std, tests, docs
cnt() { git ls-files -z -- "$@" | python3 -c '
import os, sys
n=f=0
for p in sys.stdin.buffer.read().split(b"\0"):
    if not p or not os.path.isfile(p): continue
    d=open(p,"rb").read()
    if b"\0" in d[:8192]: continue
    n+=d.count(b"\n"); f+=1
print("%6d files %8d lines" % (f, n))'; }
printf "src (hand, no parser.zig) "; cnt src rig.grammar build.zig ':!src/parser.zig'
printf "src/parser.zig (gen)      "; cnt src/parser.zig
printf "std                       "; cnt std
printf "tests+examples            "; cnt test examples
printf "docs (*.md)               "; cnt '*.md'
