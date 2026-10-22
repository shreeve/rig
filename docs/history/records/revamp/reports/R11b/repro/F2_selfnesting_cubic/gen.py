# python3 gen.py N  -> lib.rig with N chained pub generic functions, main.rig calling the last
import sys
n=int(sys.argv[1]); L=[]
for i in range(n):
    body = f"  f{i-1}(a, b) + 1\n" if i else "  1\n"
    L.append(f"pub fun f{i}[T](a: T, b: T) -> Int\n{body}")
open("lib.rig","w").write("\n".join(L))
open("main.rig","w").write("use lib\n\nsub main()\n  print(lib.f%d(1, 2))\n" % (n-1))
