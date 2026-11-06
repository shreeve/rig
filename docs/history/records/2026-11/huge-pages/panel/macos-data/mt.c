#include <stdio.h>
#include <stdlib.h>
#include <pthread.h>
#include <sys/mman.h>
#include <mach/mach_time.h>
#define PG 16384
static size_t PER; static int T; static char *shared; static int mode;
static double ns(void){ static mach_timebase_info_data_t tb; if(!tb.denom) mach_timebase_info(&tb); return (double)mach_absolute_time()*tb.numer/tb.denom; }
typedef struct { int i; double t; } arg;
static void* run(void*a_){ arg*a=a_; char*p; 
  if(mode==0) p=shared+(size_t)a->i*PER; else { p=mmap(0,PER,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANON,-1,0);} 
  double t=ns(); 
  if(mode==2) madvise(p,PER,MADV_WILLNEED);
  for(size_t o=0;o<PER;o+=PG) p[o]=1; a->t=ns()-t; return 0; }
int main(int argc,char**argv){ T=atoi(argv[1]); PER=(size_t)atol(argv[2])<<20; mode=atoi(argv[3]);
  if(mode==0) shared=mmap(0,PER*T,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANON|MAP_NORESERVE,-1,0);
  pthread_t th[64]; arg a[64]; double t0=ns();
  for(int i=0;i<T;i++){ a[i].i=i; pthread_create(&th[i],0,run,&a[i]); }
  double mx=0,sum=0; for(int i=0;i<T;i++){ pthread_join(th[i],0); if(a[i].t>mx) mx=a[i].t; sum+=a[i].t; }
  double pages=(double)PER/PG;
  printf("threads %d, %zu MiB each, %s: slowest %.2f ms, mean %.0f ns/fault\n",T,PER>>20,mode==0?"one shared mapping":mode==1?"a mapping per thread":"per thread + WILLNEED",mx/1e6,sum/T/pages);
  return 0; }
