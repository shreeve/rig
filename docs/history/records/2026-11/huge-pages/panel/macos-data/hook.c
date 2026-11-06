#include <stdlib.h>
#include <unistd.h>
#include <stdint.h>
#include <mach/mach_time.h>
static int fd=-1; static int sent=0;
static void send(void){ if(fd<0||sent) return; sent=1; uint64_t t=mach_absolute_time(); write(fd,&t,8); }
__attribute__((constructor)) static void init(void){ const char*s=getenv("EXIT_FD"); if(s){ fd=atoi(s); uint64_t t=mach_absolute_time(); write(fd,&t,8);} atexit(send); }
void my_exit(int c){ send(); exit(c); }
void my__exit(int c){ send(); _exit(c); }
__attribute__((used)) static struct { const void* r; const void* o; } interposers[] __attribute__((section("__DATA,__interpose"))) = {
 { (const void*)my_exit, (const void*)exit }, { (const void*)my__exit, (const void*)_exit } };
