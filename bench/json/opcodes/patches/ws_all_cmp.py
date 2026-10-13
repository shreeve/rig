"""Whitespace: the scalar loop, plus a 16-byte step when all 16 are whitespace (four compares, `all()`)."""
from _ws import make_all, CMP
patch = make_all(CMP)
