// A machine canary: every 1 ms a thread wakes from nanosleep and pings a
// second thread over loopback TCP; it logs any wake late by >2 ms or any
// round trip over 2 ms, with the wall time in ns. Ends after argv[1] s.
#include <arpa/inet.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>
static uint64_t now(void) { struct timespec t; clock_gettime(CLOCK_REALTIME, &t); return (uint64_t)t.tv_sec * 1000000000ull + t.tv_nsec; }
static int srvfd;
static void *echo(void *_) {
  int c = accept(srvfd, 0, 0); int one = 1; setsockopt(c, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
  char b[8]; for (;;) { ssize_t n = recv(c, b, 8, MSG_WAITALL); if (n <= 0) return 0; send(c, b, 8, 0); }
}
int main(int argc, char **argv) {
  int secs = argc > 1 ? atoi(argv[1]) : 60;
  srvfd = socket(AF_INET, SOCK_STREAM, 0);
  struct sockaddr_in a = {.sin_family = AF_INET, .sin_addr.s_addr = htonl(INADDR_LOOPBACK)}; socklen_t l = sizeof a;
  bind(srvfd, (void *)&a, sizeof a); listen(srvfd, 1); getsockname(srvfd, (void *)&a, &l);
  pthread_t th; pthread_create(&th, 0, echo, 0);
  int c = socket(AF_INET, SOCK_STREAM, 0); connect(c, (void *)&a, sizeof a); int one = 1; setsockopt(c, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
  uint64_t end = now() + (uint64_t)secs * 1000000000ull; uint64_t n = 0, worst_t = 0, worst_r = 0;
  setvbuf(stdout, 0, _IOLBF, 0);
  while (now() < end) {
    uint64_t want = now() + 1000000; struct timespec d = {0, 1000000}; nanosleep(&d, 0);
    uint64_t t0 = now(); char b[8]; send(c, &t0, 8, 0); recv(c, b, 8, MSG_WAITALL); uint64_t t1 = now();
    uint64_t late = t0 > want ? t0 - want : 0, rtt = t1 - t0; n++;
    if (late > worst_t) worst_t = late; if (rtt > worst_r) worst_r = rtt;
    if (late > 2000000) printf("C late %llu %llu\n", (unsigned long long)t0, (unsigned long long)(late / 1000));
    if (rtt > 2000000) printf("C rtt %llu %llu\n", (unsigned long long)t0, (unsigned long long)(rtt / 1000));
  }
  printf("C done %llu pings, worst late %llu us, worst rtt %llu us\n", (unsigned long long)n, (unsigned long long)(worst_t / 1000), (unsigned long long)(worst_r / 1000));
  return 0;
}
