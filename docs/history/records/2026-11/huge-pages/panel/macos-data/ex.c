#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <mach/mach_time.h>
static double ns(void){ static mach_timebase_info_data_t tb; if(!tb.denom) mach_timebase_info(&tb); return (double)mach_absolute_time()*tb.numer/tb.denom; }
// child: M mappings of S MiB each (NORESERVE), touch T KiB in each spread over the range; report exit cost; also munmap cost
int main(int argc,char**argv){ int M=atoi(argv[1]); size_t S=(size_t)atol(argv[2])<<20; size_t T=(size_t)atol(argv[3])<<10; int unmap=argc>4;
 for(int r=0;r<5;r++){ int fd[2]; pipe(fd); pid_t c=fork();
  if(c==0){ char**m=malloc(M*sizeof*m); for(int i=0;i<M;i++){ m[i]=mmap(0,S,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANON|MAP_NORESERVE,-1,0); size_t step=S/(T/16384); for(size_t o=0;o<S;o+=step) m[i][o]=1; }
    double u=0; if(unmap){ double t=ns(); for(int i=0;i<M;i++) munmap(m[i],S); u=ns()-t; }
    double t=ns(); write(fd[1],&t,8); write(fd[1],&u,8); _exit(0);} 
  double t,u; read(fd[0],&t,8); read(fd[0],&u,8); int st; waitpid(c,&st,0); double e=ns();
  printf("%d maps x %zu MiB, %zu KiB touched each (%.0f MiB resident): munmap %.2f ms, exit %.2f ms\n",M,S>>20,T>>10,M*(double)T/1048576,u/1e6,(e-t)/1e6); close(fd[0]); close(fd[1]); }
 return 0; }
