"""Escapes: the runs between them copied 8 bytes at a time while scanned (SWAR, U64 store, keep k)."""
from _esc import make, COPY8
patch = make(COPY8)
