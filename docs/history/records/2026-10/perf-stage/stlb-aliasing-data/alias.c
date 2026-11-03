// alias.c NT HOTPAGES COLOR [WIDE]: NT tables, each in its own 2 MiB-aligned reservation 512 MiB apart,
// read at random within their first HOTPAGES pages (the hot low slots), plus (WIDE) one read in
// 16 MiB of each per 8. COLOR 0: every table starts at its reservation (2 MiB-aligned, as Rig's);
// COLOR 1: table k starts k*(4096+64) bytes in.
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
int main(int argc, char **argv) {
  int nt = atoi(argv[1]), hot = atoi(argv[2]), color = atoi(argv[3]), wide = argc > 4 ? atoi(argv[4]) : 0;
  size_t gap = 64ul << 20;
  char *r = mmap(0, gap * (nt + 1), PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
  if (r == MAP_FAILED) { perror("mmap"); return 1; }
  char *base = (char *)(((uintptr_t)r + (2 << 20) - 1) & ~(uintptr_t)((2 << 20) - 1));
  uint32_t *t[256];
  for (int k = 0; k < nt; k++) {
    t[k] = (uint32_t *)(base + k * gap + (color ? (size_t)k * (4096 + 64) : 0));
    madvise((char *)t[k] - ((uintptr_t)t[k] & 4095), 2 << 20, MADV_NOHUGEPAGE);
    for (size_t i = 0; i < (size_t)hot * 1024 + (wide ? 4u << 20 : 0); i++) t[k][i] = (uint32_t)(i * 2654435761u);
  }
  uint64_t x = 88172645463325252ull, s = 0;
  size_t hs = (size_t)hot * 1024;
  for (long n = 0; n < 200000000; n++) {
    x ^= x << 13; x ^= x >> 7; x ^= x << 17;
    int k = (int)((x >> 40) % nt);
    size_t i = (x & 0xffffff) % hs;
    if (wide && (n & 7) == 0) i = (x >> 8) % (4u << 20);
    s += t[k][i];
  }
  printf("%llu\n", (unsigned long long)s);
  return 0;
}
