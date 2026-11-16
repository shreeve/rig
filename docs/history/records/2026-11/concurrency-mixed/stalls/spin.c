// Background load: argv[1] threads spinning for argv[2] seconds.
#include <pthread.h>
#include <stdlib.h>
#include <time.h>
static time_t end;
static void *spin(void *_) { volatile unsigned long x = 0; while (time(0) < end) for (int i = 0; i < 1000000; i++) x += i; return 0; }
int main(int argc, char **argv) {
  int n = atoi(argv[1]); end = time(0) + atoi(argv[2]);
  pthread_t t[64]; for (int i = 0; i < n && i < 64; i++) pthread_create(&t[i], 0, spin, 0);
  for (int i = 0; i < n && i < 64; i++) pthread_join(t[i], 0);
  return 0;
}
