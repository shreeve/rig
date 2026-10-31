// tabjit: Trig's Table growth as a model, under five huge-page policies.
//
//   tabjit ARM [F] [SEED]
//
// 40 reserved tables (4 GiB of address space each, MAP_NORESERVE, 2 MiB
// aligned), filled to the page counts Trig's ts-pattern faults in its
// Tables (fault-ahead/kernel.md: 5545, 4503, ... pages, 126 MiB in all),
// 64 bytes a push, the tables chosen at random in proportion to their
// size so all grow together, with four 8-byte reads of written slots at
// random after each push (the TLB's share). The first 2 MiB of each table
// keeps small pages (MADV_NOHUGEPAGE), as table.zig's reserve does.
//
// ARM:
//   small     no advice past the first 2 MiB (main with its gate shut)
//   whole     MADV_HUGEPAGE on the rest at reserve (main with it open)
//   gate      `whole` only while more than F free 2 MiB blocks (main, F 64)
//   jit       each 2 MiB window advised as the push frontier reaches it,
//             while at least F free 2 MiB blocks remain (one buddyinfo
//             read a window)
//   collapse  each window, once filled in small pages, MADV_COLLAPSE'd
//             while at least F free 2 MiB blocks remain
//   breaker   each window advised as the frontier reaches it and faulted
//             at once (MADV_POPULATE_WRITE), compacting if it must, until
//             one window takes more than 1 ms; after that, as `jit`
//   stash     a helper thread, on the second CPU the run may use (else on
//             the pusher's), keeps K
//             (F) 2 MiB regions advised MADV_HUGEPAGE and populated
//             ahead (it compacts, off the pushing thread); each window the
//             frontier reaches takes one by mremap (a huge page moves as
//             one PMD), else stays small
//   stash4k   the same with the helper's regions in small pages
//             (MADV_NOHUGEPAGE): faults moved off the pushing thread only
//
// Prints one line: wall, user and system ms, minor faults, the windows
// asked for, buddyinfo reads, the slowest window's first write (or
// collapse) in ms, the time all windows' first writes took, and the
// change in /proc/vmstat's THP and compaction counters over the run
// (the whole machine's).
#define _GNU_SOURCE
#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <linux/futex.h>
#include <sys/resource.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>

#ifndef MADV_COLLAPSE
#define MADV_COLLAPSE 25
#endif

#define HP (2L << 20)
#define RES (4L << 30)
#define PUSH 64

static const long pages_big[] = {5545, 4503, 4004, 3977, 3286, 2655, 2100, 1324, 1224, 602};
#define NT 40

static double now(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return t.tv_sec + t.tv_nsec / 1e9;
}

// Free 2 MiB units in blocks of order 9 and up outside the DMA zone, as
// Rig's gate counts them.
static long reads;
static long huge_free(void) {
  reads++;
  FILE *f = fopen("/proc/buddyinfo", "r");
  char line[512];
  long units = 0;
  while (fgets(line, sizeof line, f)) {
    char *p = strstr(line, "zone") + 4;
    while (*p == ' ') p++;
    char *name = p;
    while (*p && *p != ' ') p++;
    if (p - name == 3 && !strncmp(name, "DMA", 3)) continue;
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

static const char *keys[] = {"thp_fault_alloc", "thp_fault_fallback", "thp_collapse_alloc",
                             "compact_stall", "compact_success", "compact_fail"};
#define NK 6
static void vmstat(long *v) {
  FILE *f = fopen("/proc/vmstat", "r");
  char k[128];
  long x;
  memset(v, 0, NK * sizeof *v);
  while (fscanf(f, "%127s %ld", k, &x) == 2)
    for (int i = 0; i < NK; i++)
      if (!strcmp(k, keys[i])) v[i] = x;
  fclose(f);
}

// The stash: a ring of populated 2 MiB regions, filled by the helper.
#define KMAX 64
static char *ring[KMAX];
static atomic_long head, tail, stop_helper;
static _Atomic unsigned epoch;
static long K;
static int stash_huge;
static int cpu_main = -1, cpu_helper = -1;
static double helper_busy;
static void *helper(void *x) {
  (void)x;
  if (cpu_helper >= 0) {
    cpu_set_t s;
    CPU_ZERO(&s);
    CPU_SET(cpu_helper, &s);
    sched_setaffinity(0, sizeof s, &s);
  }
  while (!atomic_load(&stop_helper)) {
    unsigned e = atomic_load(&epoch);
    if (atomic_load(&tail) - atomic_load(&head) >= K) {
      // Full: wait for the pusher to take one, as the Rig arm does.
      syscall(SYS_futex, &epoch, FUTEX_WAIT_PRIVATE, e, 0, 0, 0);
      continue;
    }
    double s0 = now();
    char *m = mmap(0, 2 * HP, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
    char *p = (char *)(((uintptr_t)m + HP - 1) & ~(HP - 1));
    if (p > m) munmap(m, p - m);
    if (m + 2 * HP > p + HP) munmap(p + HP, m + 2 * HP - (p + HP));
    madvise(p, HP, stash_huge ? MADV_HUGEPAGE : MADV_NOHUGEPAGE);
    // Written a byte a page, by faults (the region's own lock), as the
    // Rig arm does; MADV_POPULATE_WRITE holds the process's.
    for (long i = 0; i < HP; i += 4096) ((volatile char *)p)[i] = 0;
    helper_busy += now() - s0;
    ring[atomic_load(&tail) % KMAX] = p;
    atomic_fetch_add(&tail, 1);
  }
  return 0;
}

static uint64_t rng = 0x9e3779b97f4a7c15;
static inline uint64_t next(void) {
  rng ^= rng << 13;
  rng ^= rng >> 7;
  rng ^= rng << 17;
  return rng;
}

int main(int argc, char **argv) {
  const char *arm = argc > 1 ? argv[1] : "small";
  long F = argc > 2 ? atol(argv[2]) : 4;
  if (argc > 3) rng = strtoull(argv[3], 0, 0) | 1;
  int a_small = !strcmp(arm, "small"), a_whole = !strcmp(arm, "whole"), a_gate = !strcmp(arm, "gate"),
      a_jit = !strcmp(arm, "jit"), a_col = !strcmp(arm, "collapse"), a_brk = !strcmp(arm, "breaker"),
      a_st = !strcmp(arm, "stash") || !strcmp(arm, "stash4k");
  stash_huge = !strcmp(arm, "stash");
  int tripped = 0;
  long hits = 0;
  if (!(a_small || a_whole || a_gate || a_jit || a_col || a_brk || a_st)) { fprintf(stderr, "tabjit: unknown arm %s\n", arm); return 2; }

  long want[NT], len[NT], edge[NT], total = 0;
  char *base[NT];
  for (int t = 0; t < NT; t++) {
    want[t] = (t < 10 ? pages_big[t] : 108) * 4096L;
    total += want[t];
  }
  {  // The first two CPUs the run may use: the pusher's, the helper's.
    cpu_set_t s;
    sched_getaffinity(0, sizeof s, &s);
    for (int i = 0; i < CPU_SETSIZE; i++)
      if (CPU_ISSET(i, &s)) {
        if (cpu_main < 0) cpu_main = i;
        else if (cpu_helper < 0) cpu_helper = i;
      }
    cpu_set_t m;
    CPU_ZERO(&m);
    CPU_SET(cpu_main, &m);
    sched_setaffinity(0, sizeof m, &m);
  }
  long v0[NK], v1[NK];
  vmstat(v0);
  struct rusage r0, r1, t0u, t1u;
  getrusage(RUSAGE_SELF, &r0);
  getrusage(RUSAGE_THREAD, &t0u);
  double t0 = now();
  pthread_t th;
  if (a_st) {
    K = F > KMAX ? KMAX : F;
    pthread_create(&th, 0, helper, 0);
  }

  long asked = 0;
  double worst = 0, wsum = 0;
  for (int t = 0; t < NT; t++) {
    char *m = mmap(0, RES + HP, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
    if (m == MAP_FAILED) { perror("mmap"); return 1; }
    char *p = (char *)(((uintptr_t)m + HP - 1) & ~(HP - 1));
    base[t] = p;
    len[t] = 0;
    edge[t] = HP;
    madvise(p, HP, MADV_NOHUGEPAGE);
    if (a_whole || (a_gate && huge_free() > F)) {
      madvise(p + HP, RES - HP, MADV_HUGEPAGE);
      asked += (want[t] + HP - 1) / HP - 1;
    }
  }

  // Pushes: table t with probability want[t]/total, by a cumulative table.
  long cum[NT];
  long c = 0;
  for (int t = 0; t < NT; t++) cum[t] = (c += want[t] / PUSH);
  long pushes = c, written = 0;
  volatile uint64_t sink = 0;
  for (long i = 0; i < pushes; i++) {
    long r = next() % c;
    int t = 0;
    while (cum[t] <= r) t++;
    if (len[t] >= want[t]) {  // full: take the next table not full
      for (t = 0; t < NT && len[t] >= want[t]; t++);
      if (t == NT) break;
    }
    char *at = base[t] + len[t];
    if (len[t] == edge[t]) {
      // The frontier reaches a new 2 MiB window.
      int timed = 0;
      if (a_st && atomic_load(&head) < atomic_load(&tail)) {
        char *src = ring[atomic_load(&head) % KMAX];
        atomic_fetch_add(&head, 1);
        atomic_fetch_add(&epoch, 1);
        syscall(SYS_futex, &epoch, FUTEX_WAKE_PRIVATE, 1, 0, 0, 0);
        double s = now();
        if (mremap(src, HP, HP, MREMAP_MAYMOVE | MREMAP_FIXED, at) == MAP_FAILED) perror("mremap");
        double d = now() - s;
        wsum += d;
        if (d > worst) worst = d;
        hits++;
        asked++;
      }
      if (a_brk && !tripped) {
        double s = now();
        madvise(at, HP, MADV_HUGEPAGE);
        madvise(at, HP, MADV_POPULATE_WRITE);
        double d = now() - s;
        wsum += d;
        if (d > worst) worst = d;
        if (d > 1e-3) tripped = 1;
        asked++;
      } else if (a_brk && huge_free() >= F) {
        madvise(at, HP, MADV_HUGEPAGE);
        asked++;
        timed = 1;
      }
      if (a_jit && huge_free() >= F) {
        madvise(at, HP, MADV_HUGEPAGE);
        asked++;
        timed = 1;
      }
      if (a_col && edge[t] > HP && huge_free() >= F) {
        double s = now();
        madvise(at - HP, HP, MADV_COLLAPSE);
        double d = now() - s;
        wsum += d;
        if (d > worst) worst = d;
        asked++;
      }
      if (a_whole || a_gate) timed = 1;
      edge[t] += HP;
      if (timed) {
        double s = now();
        memset(at, 1, PUSH);
        double d = now() - s;
        wsum += d;
        if (d > worst) worst = d;
      } else {
        memset(at, 1, PUSH);
      }
    } else {
      memset(at, 1, PUSH);
    }
    len[t] += PUSH;
    written += PUSH;
    for (int k = 0; k < 4; k++) {
      int u = next() % NT;
      if (len[u] == 0) continue;
      sink += *(uint64_t *)(base[u] + (next() % len[u] & ~7L));
    }
  }

  double wall = now() - t0;
  getrusage(RUSAGE_THREAD, &t1u);
  if (a_st) {
    atomic_store(&stop_helper, 1);
    atomic_fetch_add(&epoch, 1);
    syscall(SYS_futex, &epoch, FUTEX_WAKE_PRIVATE, 1, 0, 0, 0);
    pthread_join(th, 0);
  }
  getrusage(RUSAGE_SELF, &r1);
  vmstat(v1);
  FILE *f = fopen("/proc/self/smaps_rollup", "r");
  char line[256];
  long anon_huge = 0, rss = 0;
  while (fgets(line, sizeof line, f)) {
    if (!strncmp(line, "AnonHugePages:", 14)) anon_huge = atol(line + 14);
    if (!strncmp(line, "Rss:", 4)) rss = atol(line + 4);
  }
  fclose(f);
  printf("arm=%s F=%ld wall_ms=%.1f user_ms=%.1f sys_ms=%.1f minflt=%ld asked=%ld reads=%ld worst_ms=%.2f windows_ms=%.1f huge_mib=%ld rss_mib=%ld written_mib=%ld",
         arm, F, wall * 1e3,
         (r1.ru_utime.tv_sec - r0.ru_utime.tv_sec) * 1e3 + (r1.ru_utime.tv_usec - r0.ru_utime.tv_usec) / 1e3,
         (r1.ru_stime.tv_sec - r0.ru_stime.tv_sec) * 1e3 + (r1.ru_stime.tv_usec - r0.ru_stime.tv_usec) / 1e3,
         r1.ru_minflt - r0.ru_minflt, asked, reads, worst * 1e3, wsum * 1e3, anon_huge >> 10, rss >> 10,
         written >> 20);
  for (int i = 0; i < NK; i++) printf(" %s=%ld", keys[i], v1[i] - v0[i]);
  printf(" tripped=%d hits=%ld helper_ms=%.1f main_user_ms=%.1f main_sys_ms=%.1f sink=%lu\n", tripped, hits, helper_busy * 1e3,
         (t1u.ru_utime.tv_sec - t0u.ru_utime.tv_sec) * 1e3 + (t1u.ru_utime.tv_usec - t0u.ru_utime.tv_usec) / 1e3,
         (t1u.ru_stime.tv_sec - t0u.ru_stime.tv_sec) * 1e3 + (t1u.ru_stime.tv_usec - t0u.ru_stime.tv_usec) / 1e3,
         (unsigned long)(sink & 1));
  return 0;
}
