// frag: fragments pup's free memory on purpose, holds it, and frees it
// all when it gets SIGTERM (or its stdin closes).
//
//   frag [KEEP_AVAIL_MB] [MAX_MAP_MB] [LEAVE]
//
// 1. Maps M bytes of 4 KiB pages (MADV_NOHUGEPAGE) and writes them all,
//    M = min(MemFree - 512 MiB, MemAvailable - KEEP_AVAIL_MB, MAX_MAP_MB):
//    the buddy allocator hands out its smallest free blocks first, so this
//    takes the free memory of orders 0 to 8 before any 2 MiB block.
// 2. Frees every other 4 KiB page of it (MADV_DONTNEED): M/2 bytes come
//    back as single free pages whose buddies are held, so none merge.
// 3. Takes every free block of 2 MiB or more that is left (orders 9 and
//    10 in /proc/buddyinfo), by mapping as many 2 MiB pages advised
//    MADV_HUGEPAGE and writing them, and holds them. Given LEAVE, it
//    takes all but LEAVE of those outside the DMA zone (as Rig's gate
//    counts them), so the run after it starts with about LEAVE free.
// It prints /proc/buddyinfo after each step, then "ready", and waits.
// What it holds at the end is M/2 plus the 2 MiB blocks it took; the most
// it holds is M, during step 1, so MemAvailable never falls below
// KEEP_AVAIL_MB (default 13312, 13 GiB) by its doing.
#define _GNU_SOURCE
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#ifndef MADV_POPULATE_WRITE
#define MADV_POPULATE_WRITE 23
#endif

static long meminfo(const char *key) {
  FILE *f = fopen("/proc/meminfo", "r");
  char line[256];
  long v = -1;
  size_t n = strlen(key);
  while (fgets(line, sizeof line, f))
    if (!strncmp(line, key, n) && line[n] == ':') { v = atol(line + n + 1); break; }
  fclose(f);
  return v * 1024;
}

// Free 2 MiB units in blocks of order 9 and up, every zone, or (nodma)
// every zone but DMA, as Rig's gate counts them.
static long huge_free_in(int nodma) {
  FILE *f = fopen("/proc/buddyinfo", "r");
  char line[512];
  long units = 0;
  while (fgets(line, sizeof line, f)) {
    char *p = strstr(line, "zone");
    p += 4;
    while (*p == ' ') p++;
    char *name = p;
    while (*p && *p != ' ') p++;  // the zone's name
    if (nodma && p - name == 3 && !strncmp(name, "DMA", 3)) continue;
    for (int order = 0; order <= 10; order++) {
      char *e;
      long c = strtol(p, &e, 10);
      if (e == p) break;
      p = e;
      if (order >= 9) units += c << (order - 9);
    }
  }
  fclose(f);
  return units;
}
static long huge_free(void) { return huge_free_in(0); }

static void buddy(const char *what) {
  FILE *f = fopen("/proc/buddyinfo", "r");
  char line[512];
  printf("# %s: MemFree %ld MiB, MemAvailable %ld MiB, free 2 MiB units %ld\n", what,
         meminfo("MemFree") >> 20, meminfo("MemAvailable") >> 20, huge_free());
  while (fgets(line, sizeof line, f)) printf("#   %s", line);
  fclose(f);
  fflush(stdout);
}

static double now(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return t.tv_sec + t.tv_nsec / 1e9;
}

static volatile sig_atomic_t done;
static void stop(int s) { (void)s; done = 1; }

int main(int argc, char **argv) {
  long keep = (argc > 1 ? atol(argv[1]) : 13312) << 20;
  long cap = (argc > 2 ? atol(argv[2]) : 1L << 20) << 20;
  long leave = argc > 3 ? atol(argv[3]) : -1;
  const long pg = 4096, hp = 2L << 20;
  double t0 = now();
  buddy("before");
  long m = meminfo("MemFree") - (512L << 20);
  long a = meminfo("MemAvailable") - keep;
  if (a < m) m = a;
  if (cap < m) m = cap;
  m &= ~(hp - 1);
  if (m <= 0) { printf("# not enough memory to fragment\n"); return 1; }
  char *p = mmap(0, m, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
  if (p == MAP_FAILED) { perror("mmap"); return 1; }
  madvise(p, m, MADV_NOHUGEPAGE);
  for (long off = 0; off < m; off += 64L << 20) {
    long n = m - off < (64L << 20) ? m - off : 64L << 20;
    if (madvise(p + off, n, MADV_POPULATE_WRITE)) for (long i = 0; i < n; i += pg) p[off + i] = 1;
  }
  printf("# step 1: mapped and wrote %ld MiB in %.1f s\n", m >> 20, now() - t0);
  buddy("after step 1");
  for (long off = pg; off < m; off += 2 * pg) madvise(p + off, pg, MADV_DONTNEED);
  printf("# step 2: freed every other page, %ld MiB, at %.1f s\n", (m / 2) >> 20, now() - t0);
  buddy("after step 2");
  long u = huge_free(), took = 0;
  if (leave >= 0) { u = huge_free_in(1) - leave; if (u < 0) u = 0; }
  if (u > 0) {
    long n = u * hp;
    char *r = mmap(0, n + hp, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    char *q = (char *)(((unsigned long)r + hp - 1) & ~(hp - 1));
    madvise(q, n, MADV_HUGEPAGE);
    if (madvise(q, n, MADV_POPULATE_WRITE)) for (long i = 0; i < n; i += pg) q[i] = 1;
    took = n;
  }
  printf("# step 3: took %ld free 2 MiB blocks, %ld MiB, at %.1f s\n", u, took >> 20, now() - t0);
  buddy("ready");
  printf("ready held_mib=%ld\n", (m / 2 + took) >> 20);
  fflush(stdout);
  signal(SIGTERM, stop);
  signal(SIGINT, stop);
  signal(SIGHUP, stop);
  while (!done) pause();
  return 0;
}
