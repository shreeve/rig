#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <stdint.h>
#include <sys/wait.h>
#include <sys/resource.h>
#include <fcntl.h>
#include <mach/mach_time.h>
int main(int argc,char**argv){ mach_timebase_info_data_t tb; mach_timebase_info(&tb);
 int p[2]; pipe(p); char buf[16]; snprintf(buf,sizeof buf,"%d",p[1]); setenv("EXIT_FD",buf,1); if(getenv("HOOK")) setenv("DYLD_INSERT_LIBRARIES",getenv("HOOK"),1);
 uint64_t t0=mach_absolute_time(); pid_t c=fork();
 if(c==0){ close(p[0]); int dn=open("/dev/null",O_WRONLY); dup2(dn,1); execv(argv[1],argv+1); _exit(127);} 
 close(p[1]); uint64_t ts[4]; int n=0; while(n<4 && read(p[0],&ts[n],8)==8) n++;
 int st; struct rusage ru; wait4(c,&st,0,&ru); uint64_t te=mach_absolute_time();
 double k=(double)tb.numer/tb.denom/1e6;
 if(n>=2) fprintf(stderr,"start->ctor %.2f ms  ctor->exit %.2f ms  exit->reaped %.2f ms  total %.2f ms  minflt %ld\n",(ts[0]-t0)*k,(ts[1]-ts[0])*k,(te-ts[1])*k,(te-t0)*k,ru.ru_minflt);
 else fprintf(stderr,"n=%d total %.2f\n",n,(te-t0)*k);
 return 0; }
