// unfrag N: makes at least N free blocks of 2 MiB, as far as compaction
// can, with no privilege: maps N pages of 2 MiB advised MADV_HUGEPAGE and
// writes them (under defrag=madvise each fault compacts memory until it
// gets a 2 MiB block), then unmaps them, which frees N blocks of 2 MiB.
// Prints how many of the N were huge pages.
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#ifndef MADV_POPULATE_WRITE
#define MADV_POPULATE_WRITE 23
#endif
int main(int argc, char **argv) {
  long n = argc > 1 ? atol(argv[1]) : 128, hp = 2L << 20;
  char *r = mmap(0, (n + 1) * hp, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
  char *q = (char *)(((unsigned long)r + hp - 1) & ~(hp - 1));
  madvise(q, n * hp, MADV_HUGEPAGE);
  if (madvise(q, n * hp, MADV_POPULATE_WRITE)) for (long i = 0; i < n * hp; i += 4096) q[i] = 1;
  FILE *f = fopen("/proc/self/smaps_rollup", "r");
  char line[256];
  long kb = 0;
  while (fgets(line, sizeof line, f)) if (!strncmp(line, "AnonHugePages:", 14)) kb = atol(line + 14);
  fclose(f);
  printf("unfrag: %ld of %ld 2 MiB pages huge\n", kb / 2048, n);
  return 0;
}
