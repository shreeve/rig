"""Mutation check only: ws_tbl whose table forgets TAB; optest must fail."""
from _ws import make, VECTOR_RUN, TBL
patch = make(VECTOR_RUN, TBL.replace("0x09, 0x0A", "0, 0x0A"))
