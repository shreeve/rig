#!/usr/bin/env python3
"""loopgen-x86.py OFFSET... > loop.c: the x86-64 twin of loopgen.py (for a
pup job): qsort's partition loop in the same block shape (loop top on the
low push path, the shared counter block, both push paths, dead slots for
the grow calls), one copy per OFFSET, each in its own 64 KiB-aligned region
with its loop top OFFSET bytes in. Same harness and output as loopgen.py.
Build: cc -O2 -o loop loop.c; run: taskset -c 3 ./loop 21 (inside a pup
timing slot)."""
import sys
offs = [int(x, 0) for x in sys.argv[1:]]
asm = []
for i, off in enumerate(offs):
    assert off >= 64
    asm.append(r'''
.p2align 16
.globl part%(i)d
part%(i)d:
  push %%rbx
  push %%r12
  xor %%r10d, %%r10d
  xor %%r11d, %%r11d
  xor %%eax, %%eax
  xor %%r12d, %%r12d
  jmp 5f
.space %(off)d - (. - part%(i)d), 0x90
0: mov %%rbx, (%%rcx,%%r10,8)
  inc %%r10
1: inc %%r11
  cmp %%r11, %%rsi
  je 9f
5: mov (%%rdi,%%r11,8), %%rbx
  cmp %%rdx, %%rbx
  jge 2f
  cmp $-1, %%r10
  jne 0b
  ud2
  ud2
  ud2
  ud2
  ud2
  ud2
  ud2
  jmp 0b
2: jle 4f
  cmp $-1, %%rax
  jne 3f
  ud2
  ud2
  ud2
  ud2
  ud2
  ud2
  ud2
3: mov %%rbx, (%%r8,%%rax,8)
  inc %%rax
  jmp 1b
4: mov %%rbx, (%%r9,%%r12,8)
  inc %%r12
  jmp 1b
9: shl $20, %%r10
  add %%r10, %%rax
  pop %%r12
  pop %%rbx
  ret
''' % {"i": i, "off": off})
n = len(offs)
print(r'''#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <time.h>
#include <string.h>
typedef long (*partf)(const long *a, long n, long p, long *lo, long *hi, long *mid);''')
for i in range(n): print("long part%d();" % i)
print("__asm__(\".text\\n\"\n" + "\n".join('"%s\\n"' % l for a in asm for l in a.splitlines() if l) + ");")
print("static partf parts[] = {%s};" % ", ".join("(partf)part%d" % i for i in range(n)))
print("static const long offs[] = {%s};" % ", ".join(str(o) for o in offs))
print(r'''
static double now(void){struct timespec t;clock_gettime(CLOCK_MONOTONIC_RAW,&t);return t.tv_sec*1e3+t.tv_nsec/1e6;}
static int cmpd(const void*a,const void*b){double x=*(double*)a,y=*(double*)b;return x<y?-1:x>y;}
int main(int argc,char**argv){
  int N=%d, R=argc>1?atoi(argv[1]):15; long n=1<<22;
  long *a=malloc(n*8),*lo=malloc(n*8),*hi=malloc(n*8),*mid=malloc(n*8);
  uint64_t x=88172645463325252ull;
  for(long i=0;i<n;i++){x=x*6364136223846793005ull+1442695040888963407ull;a[i]=(long)(x>>44);}
  memset(lo,0,n*8);memset(hi,0,n*8);memset(mid,0,n*8);
  double *t=malloc(sizeof(double)*N*R); long c0=-1;
  for(int r=0;r<R;r++) for(int j=0;j<N;j++){int k=(j+r)%%N;
    double s=now(); long c=parts[k](a,n,a[n/2],lo,hi,mid); t[k*R+r]=now()-s;
    if(c0<0)c0=c; else if(c!=c0){printf("bad check %%ld %%ld\n",c,c0);return 1;}}
  for(int k=0;k<N;k++){qsort(t+k*R,R,sizeof(double),cmpd);
    printf("off %%6ld (0x%%04lx) mod64 %%2ld median %%.3f [%%.3f-%%.3f] ms\n",offs[k],offs[k],offs[k]%%64,t[k*R+R/2],t[k*R+R/4],t[k*R+3*R/4]);}
  printf("check %%ld\n",c0);
}''' % n)
