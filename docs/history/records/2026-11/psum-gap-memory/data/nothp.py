import ctypes, os, sys
# PR_SET_THP_DISABLE (41): no THP for this process and what it execs, MADV_HUGEPAGE included.
assert ctypes.CDLL(None, use_errno=True).prctl(41, 1, 0, 0, 0) == 0
os.execv(sys.argv[1], sys.argv[1:])
