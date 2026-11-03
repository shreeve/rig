import ctypes,os,sys
assert ctypes.CDLL(None).prctl(41,1,0,0,0)==0
os.execvp(sys.argv[1],sys.argv[1:])
