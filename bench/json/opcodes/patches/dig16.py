"""Digits: 16 at a time with SIMD (x86: pmaddubsw/pmaddwd; NEON: portable widening multiplies)."""
from _dig import make
patch = make()
