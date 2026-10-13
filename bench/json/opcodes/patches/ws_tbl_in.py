"""ws_tbl with the vector run inlined at every call site."""
from _ws import make, VECTOR_RUN, TBL
patch = make(VECTOR_RUN, TBL, inline=True)
