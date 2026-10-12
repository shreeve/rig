"""ws_cmp with the vector run inlined at every call site."""
from _ws import make, VECTOR_RUN, CMP
patch = make(VECTOR_RUN, CMP, inline=True)
