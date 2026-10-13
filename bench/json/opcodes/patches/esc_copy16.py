"""Escapes: the runs between them copied 16 bytes at a time while scanned (vector store, keep k)."""
from _esc import make, COPY16
patch = make(COPY16)
