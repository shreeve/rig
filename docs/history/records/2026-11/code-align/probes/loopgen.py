#!/usr/bin/env python3
"""loopgen.py OFFSET... > loop.c: qsort-mac's partition loop (s0's qsort,
byte for byte in layout: both push paths, the grow calls' slots, the back
branches; registers renamed to caller-saved ones), one copy per OFFSET,
each in its own 32 KiB-aligned region with its loop top (s0's 0x...bff4)
at OFFSET bytes into the region. The harness times every copy, rotating,
on 2^22 random Ints split around the middle element, as qsort's top level
does (or on sorted Ints, every branch predicted, with a second
argument `sorted`), and prints each copy's median and quartiles over the rounds."""
import sys
offs = [int(x, 0) for x in sys.argv[1:]]
asm = []
for i, off in enumerate(offs):
    assert off >= 64
    asm.append(r'''
.p2align 15
.globl _part%(i)d
_part%(i)d:
  mov x6, #0
  mov x7, #0
  mov x9, #0
  mov x11, #0
  mov x13, #-1
  mov x14, #-1
  mov x15, #-1
  b 5f
.space %(off)d - (. - _part%(i)d), 0
0: str x12, [x3, x6, lsl #3]
  add x6, x6, #1
1: add x7, x7, #1
  cmp x1, x7
  b.eq 9f
5: ldr x12, [x0, x7, lsl #3]
  cmp x12, x2
  b.ge 2f
  cmp x6, x13
  b.ne 0b
  brk #1
  brk #1
  brk #1
  brk #1
  brk #1
  brk #1
  brk #1
  b 0b
2: b.le 4f
  cmp x9, x14
  b.ne 3f
  brk #1
  brk #1
  brk #1
  brk #1
  brk #1
  brk #1
  brk #1
3: str x12, [x4, x9, lsl #3]
  add x9, x9, #1
  b 1b
4: cmp x11, x15
  b.ne 6f
  brk #1
  brk #1
  brk #1
  brk #1
  brk #1
  brk #1
  brk #1
  brk #1
6: str x12, [x5, x11, lsl #3]
  add x11, x11, #1
  b 1b
9: lsl x0, x6, #20
  add x0, x0, x9
  ret
''' % {"i": i, "off": off})
n = len(offs)
print(r'''#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <time.h>
#include <string.h>
typedef long (*partf)(const long *a, long n, long p, long *lo, long *hi, long *mid, long x6, long x7, long x8, long x9, long x10, long x11, long x12, long x13, long x14, long x15, long cap);
''')
for i in range(n):
    print("long part%d();" % i)
print("__asm__(\".text\\n\"\n" + "\n".join('"%s\\n"' % l.replace('"', r'\"') for a in asm for l in a.splitlines() if l) + ");")
print("static partf parts[] = {%s};" % ", ".join("(partf)part%d" % i for i in range(n)))
print("static const long offs[] = {%s};" % ", ".join(str(o) for o in offs))
print(r'''
static double now(void){struct timespec t;clock_gettime(CLOCK_MONOTONIC_RAW,&t);return t.tv_sec*1e3+t.tv_nsec/1e6;}
static int cmpd(const void*a,const void*b){double x=*(double*)a,y=*(double*)b;return x<y?-1:x>y;}
int main(int argc,char**argv){
  int N=%d, R=argc>1?atoi(argv[1]):15; long n=1<<22;
  long *a=malloc(n*8),*lo=malloc(n*8),*hi=malloc(n*8),*mid=malloc(n*8);
  uint64_t x=88172645463325252ull;
  int sorted=argc>2&&argv[2][0]=='s';
  for(long i=0;i<n;i++){x=x*6364136223846793005ull+1442695040888963407ull;a[i]=sorted?i:(long)(x>>44);}
  memset(lo,0,n*8);memset(hi,0,n*8);memset(mid,0,n*8);
  double *t=malloc(sizeof(double)*N*R); long c0=-1;
  for(int r=0;r<R;r++) for(int j=0;j<N;j++){int k=(j+r)%%N;
    double s=now(); long c=parts[k](a,n,a[n/2],lo,hi,mid,0,0,0,0,0,0,0,0,0,0,n); t[k*R+r]=now()-s;
    if(c0<0)c0=c; else if(c!=c0){printf("bad check %%ld %%ld\n",c,c0);return 1;}}
  for(int k=0;k<N;k++){qsort(t+k*R,R,sizeof(double),cmpd);
    printf("off %%6ld (0x%%04lx) mod128 %%3ld median %%.3f [%%.3f-%%.3f] ms\n",offs[k],offs[k],offs[k]%%128,t[k*R+R/2],t[k*R+R/4],t[k*R+3*R/4]);}
  printf("check %%ld\n",c0);
}''' % n)
