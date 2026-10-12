#!/usr/bin/env python3
"""Write json32.rig into DIR: std/json.rig with the string scan's SIMD
blocks 32 lanes wide instead of 16. Bench-only; std/json.rig is unchanged.

usage: simd32.py DIR
then:  JSON_DIR=DIR bench/json/bench-json --variants 'rig-safe@src=json32+TIER=32' ...
"""
import os, sys
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
s = open(os.path.join(ROOT, "std", "json.rig")).read()
a = s.index("fun special(v: Simd[U8, 16])")
b = s.index("# The top bit of each byte of `w`")
body = s[a:b]
new = (body.replace("Simd[U8, 16]", "Simd[U8, 32]")
           .replace("Simd[Bool, 16]", "Simd[Bool, 32]")
           .replace("i + 16 <= s.len : i += 16", "i + 32 <= s.len : i += 32")
           .replace("s.len >= 16", "s.len >= 32")
           .replace("s.len - 16", "s.len - 32")
           .replace("i + 16 - s.len", "i + 32 - s.len"))
assert new.count("32") >= 9 and "16" not in new.replace("TIER", "").split("fun skip_plain_ascii")[1].split("# Fewer")[0].replace("Simd[U8, 32]", ""), "unexpected shape"
os.makedirs(sys.argv[1], exist_ok=True)
open(os.path.join(sys.argv[1], "json32.rig"), "w").write(s[:a] + new + s[b:])
