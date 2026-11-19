import sys
pad = int(sys.argv[1])
print(r'''#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <time.h>
long part(const long *a, long n, long p, long *lo, long *hi);
__asm__(".text\n.p2align 14\nfill_start:\n.space PADV, 0\n.globl _part\n_part:\n"
"  mov x5, x3\n"
"0: ldr x9, [x0], #8\n"
"  cmp x9, x2\n"
"  b.ge 1f\n"
"  str x9, [x3], #8\n"
"  b 2f\n"
"1: str x9, [x4], #8\n"
"2: subs x1, x1, #1\n"
"  b.ne 0b\n"
"  sub x0, x3, x5\n"
"  lsr x0, x0, #3\n"
"  ret\n");
static double now(void){struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return t.tv_sec*1e3+t.tv_nsec/1e6;}
int main(void){
  long n=1<<22; long *a=malloc(n*8),*lo=malloc(n*8),*hi=malloc(n*8);
  uint64_t x=88172645463325252ull; for(long i=0;i<n;i++){x^=x<<13;x^=x>>7;x^=x<<17;a[i]=(long)(x>>20);}
  for(long i=0;i<n;i++){lo[i]=0;hi[i]=0;}
  double best=1e9; long c=0;
  for(int r=0;r<15;r++){double t=now(); c+=part(a,n,a[n/2],lo,hi); double e=now()-t; if(e<best)best=e;}
  printf("pad %d best %.3f ms check %ld\n", PADV, best, c);
}'''.replace("PADV", str(pad)))
