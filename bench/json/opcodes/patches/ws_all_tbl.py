"""Whitespace: the scalar loop, plus a 16-byte step when all 16 are whitespace (nibble lookup, `all()`)."""
from _ws import make_all, TBL
patch = make_all(TBL)
