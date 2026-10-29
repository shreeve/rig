// collapse MIB [WAY]: four ways (or the one named) to put MIB MiB of fresh memory in 2 MiB pages,
// each timed (wall and CPU, which is kernel time here), with how much of
// it ended in huge pages:
//   fault:    MADV_HUGEPAGE, then written (Rig's way: a fault per 2 MiB,
//             which compacts in the fault under defrag=madvise)
//   collapse: written in 4 KiB pages, then MADV_COLLAPSE (Linux 6.1),
//             which always compacts if it must, whatever defrag says
//   gated:    MADV_HUGEPAGE only if /proc/buddyinfo shows enough free
//             2 MiB blocks, then written
//   small:    written in 4 KiB pages, no advice
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#ifndef MADV_COLLAPSE
#define MADV_COLLAPSE 25
#endif
static const long hp = 2L << 20;
static double wall(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec / 1e9; }
static double cpu(void) { struct timespec t; clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &t); return t.tv_sec + t.tv_nsec / 1e9; }
static long units(void) {
  FILE *f = fopen("/proc/buddyinfo", "r"); char line[512]; long u = 0;
  while (fgets(line, sizeof line, f)) {
    char z[32]; long c[11]; int n = sscanf(line, "Node %*d, zone %31s %ld %ld %ld %ld %ld %ld %ld %ld %ld %ld %ld", z, c, c+1, c+2, c+3, c+4, c+5, c+6, c+7, c+8, c+9, c+10);
    if (n == 12 && strcmp(z, "DMA")) u += c[9] + 2 * c[10];
  }
  fclose(f); return u;
}
static long huge_kb(char *p, long n) {
  // AnonHugePages of the mapping holding p
  FILE *f = fopen("/proc/self/smaps", "r"); char line[256]; long kb = -1; int in = 0;
  while (fgets(line, sizeof line, f)) {
    unsigned long lo, hi;
    if (sscanf(line, "%lx-%lx ", &lo, &hi) == 2 && strchr(line, '-') && line[0] != ' ' && strstr(line, " rw")) in = (unsigned long)p >= lo && (unsigned long)p < hi;
    else if (in && !strncmp(line, "AnonHugePages:", 14)) { kb = atol(line + 14); in = 0; }
  }
  fclose(f); (void)n; return kb;
}
static char *region(long n) {
  char *r = mmap(0, n + hp, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
  return (char *)(((unsigned long)r + hp - 1) & ~(hp - 1));
}
static void touch(char *p, long n) { for (long i = 0; i < n; i += 4096) p[i] = 1; }
int main(int argc, char **argv) {
  long n = (argc > 1 ? atol(argv[1]) : 64) << 20;
  const char *ways[] = {"fault", "collapse", "gated", "small"};
  for (int w = 0; w < 4; w++) {
    if (argc > 2 && strcmp(argv[2], ways[w])) continue;
    char *p = region(n);
    long u = units();
    double w0 = wall(), c0 = cpu();
    if (w == 0) { madvise(p, n, MADV_HUGEPAGE); touch(p, n); }
    if (w == 1) { touch(p, n); madvise(p, n, MADV_COLLAPSE); }
    if (w == 2) { if (units() >= n / hp) madvise(p, n, MADV_HUGEPAGE); touch(p, n); }
    if (w == 3) touch(p, n);
    double dw = wall() - w0, dc = cpu() - c0;
    printf("%s mib=%ld units_before=%ld wall_ms=%.2f cpu_ms=%.2f huge_mib=%ld\n", ways[w], n >> 20, u, dw * 1e3, dc * 1e3, huge_kb(p, n) / 1024);
    munmap(p, n);
  }
  return 0;
}
