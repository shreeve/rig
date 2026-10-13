"""Whitespace: inlined entry, 16 lanes a step, one nibble lookup (tbl / pshufb) and a compare."""
from _ws import make, VECTOR_RUN, TBL
patch = make(VECTOR_RUN, TBL)
