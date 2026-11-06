#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/resource.h>
#include <sys/wait.h>
#include <mach/mach_time.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>

static double now_ns(void){ static mach_timebase_info_data_t tb; if(!tb.denom) mach_timebase_info(&tb); return (double)mach_absolute_time()*tb.numer/tb.denom; }
static long minflt(void){ struct rusage r; getrusage(RUSAGE_SELF,&r); return r.ru_minflt; }
#define PG 16384
static size_t N;
static char *mapit(void){ char *p=mmap(0,N,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANON,-1,0); if(p==MAP_FAILED){perror("mmap");exit(1);} return p; }
static void touch(char *p){ for(size_t i=0;i<N;i+=PG) p[i]=1; }
static void report(const char*name,double ns,long f){ double mib=N/1048576.0; printf("%-34s %8.3f ms  %7.3f ms/MiB  faults %7ld  %6.0f ns/fault\n",name,ns/1e6,ns/1e6/mib,f,f?ns/f:0); }

int main(int argc,char**argv){
  N=(size_t)(argc>1?atol(argv[1]):256)<<20;
  printf("size %zu MiB, page %ld\n",N>>20,(long)getpagesize());
  for(int rep=0;rep<3;rep++){
  printf("-- round %d\n",rep);
  // A: plain lazy faults, one write per 16K page
  { char*p=mapit(); long f=minflt(); double t=now_ns(); touch(p); t=now_ns()-t; report("lazy touch (1 write/page)",t,minflt()-f);
    // second pass: resident
    t=now_ns(); touch(p); t=now_ns()-t; report("  resident touch",t,0);
    // munmap of resident
    t=now_ns(); munmap(p,N); t=now_ns()-t; report("  munmap resident",t,0); }
  // A2: memset whole (fill all bytes)
  { char*p=mapit(); long f=minflt(); double t=now_ns(); memset(p,1,N); t=now_ns()-t; report("lazy memset all",t,minflt()-f);
    t=now_ns(); memset(p,2,N); t=now_ns()-t; report("  resident memset all",t,0); munmap(p,N);}
  // B: MADV_WILLNEED
  { char*p=mapit(); double t0=now_ns(); madvise(p,N,MADV_WILLNEED); double t1=now_ns(); long f=minflt(); touch(p); double t2=now_ns();
    report("WILLNEED call",t1-t0,0); report("  then touch",t2-t1,minflt()-f); munmap(p,N);}
  // C: mlock+munlock as populate
  { char*p=mapit(); long f=minflt(); double t0=now_ns(); int r=mlock(p,N); double t1=now_ns(); munlock(p,N); double t2=now_ns(); long f2=minflt(); touch(p); double t3=now_ns();
    if(r) perror("mlock"); report("mlock (populate)",t1-t0,f2-f); report("  munlock",t2-t1,0); report("  then touch",t3-t2,minflt()-f2); munmap(p,N);}
  // D: MADV_FREE_REUSABLE / REUSE cycle on resident memory
  { char*p=mapit(); touch(p); double t0=now_ns(); madvise(p,N,MADV_FREE_REUSABLE); double t1=now_ns(); madvise(p,N,MADV_FREE_REUSE); double t2=now_ns(); long f=minflt(); touch(p); double t3=now_ns();
    report("FREE_REUSABLE resident",t1-t0,0); report("  FREE_REUSE",t2-t1,0); report("  then touch",t3-t2,minflt()-f); munmap(p,N);}
  // E: MADV_DONTNEED / MADV_FREE resident
  { char*p=mapit(); touch(p); double t0=now_ns(); madvise(p,N,MADV_FREE); double t1=now_ns(); long f=minflt(); touch(p); double t2=now_ns();
    report("MADV_FREE resident",t1-t0,0); report("  then touch",t2-t1,minflt()-f); munmap(p,N);}
  // F: superpage flag
  { mach_vm_address_t a=0; kern_return_t kr=mach_vm_allocate(mach_task_self(),&a,N,VM_FLAGS_ANYWHERE|VM_FLAGS_SUPERPAGE_SIZE_2MB);
    printf("mach_vm_allocate SUPERPAGE_2MB: kr=%d (%s)\n",kr,mach_error_string(kr)); if(kr==0) mach_vm_deallocate(mach_task_self(),a,N);
    kr=mach_vm_allocate(mach_task_self(),&a,N,VM_FLAGS_ANYWHERE|VM_FLAGS_SUPERPAGE_SIZE_ANY);
    printf("mach_vm_allocate SUPERPAGE_ANY: kr=%d (%s)\n",kr,mach_error_string(kr)); if(kr==0) mach_vm_deallocate(mach_task_self(),a,N);}
  // G: exit teardown: child touches N, reports time just before _exit; parent times until waitpid returns
  { int fd[2]; pipe(fd); pid_t c=fork(); if(c==0){ char*p=mapit(); touch(p); double t=now_ns(); write(fd[1],&t,sizeof t); _exit(0);} 
    double t; read(fd[0],&t,sizeof t); int st; waitpid(c,&st,0); double e=now_ns(); report("exit teardown (resident N)",e-t,0); close(fd[0]); close(fd[1]); }
  { int fd[2]; pipe(fd); pid_t c=fork(); if(c==0){ double t=now_ns(); write(fd[1],&t,sizeof t); _exit(0);} 
    double t; read(fd[0],&t,sizeof t); int st; waitpid(c,&st,0); double e=now_ns(); report("exit teardown (empty child)",e-t,0); close(fd[0]); close(fd[1]); }
  }
  return 0;
}
