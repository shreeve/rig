"""Digits: 16 at a time with SIMD, the portable multiply-add chain on every target."""
from _dig import make
patch = make(madd=False)
