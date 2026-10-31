#include <sys/mman.h>
#include <stdlib.h>
#include <string.h>
/* tear N UNMAP: N tables of 3 MiB touched, as Trig 43 reserved tables hold 127 MiB; then unmapped one by one (UNMAP=1) or left to exit. */
int main(int c, char **v) {
  int n = atoi(v[1]), un = atoi(v[2]); size_t len = 3u << 20; char *p[256];
  for (int i = 0; i < n; i++) { p[i] = mmap(0, 1ul << 30, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS|MAP_NORESERVE, -1, 0); madvise(p[i], 1ul<<30, MADV_NOHUGEPAGE); memset(p[i], 1, len); }
  if (un) for (int i = 0; i < n; i++) munmap(p[i], 1ul << 30);
  return 0;
}
