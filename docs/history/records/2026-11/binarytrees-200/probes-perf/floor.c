// Floor probes for binarytrees 21 on the M5: what each mechanism costs, in C,
// apart from Rig. Usage: floor MODE THREADS [n]
//   MODE: b16  per-worker reused bump, 16-byte pointer nodes, built in walk order
//         b8   the same with 8-byte nodes, 4-byte index links
//         b16p bump, 16-byte nodes, built post-order (children first, as Rig's ^ does)
//         b16d b16 plus a drop walk that frees nothing (the cost of walking to drop)
//         fl   a free list per thread behind noinline alloc/free and a TLS read, one
//              free per node in a post-order recursive drop (Rig plain's shape)
//         nb   an arena whose bump is a noinline call reading a thread-local, walk
//              order, no per-node drop (the arena record's first stage)
//   SPLIT: THREADS jobs per depth when the env var SPLIT=depth is unset: 64 runs per
//          depth over a shared queue; SPLIT=depth gives one job per depth (Rig plain).
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <sys/mman.h>

typedef struct N16 { struct N16 *l, *r; } N16;
typedef struct { int32_t l, r; } N8;

typedef struct { char *buf; size_t cap, used; char pad[128 - 24]; } Bump; // padded: no false sharing between workers
static inline void *bump(Bump *b, size_t n) {
    if (b->used + n > b->cap) {
        size_t nc = b->cap ? b->cap * 2 : (1 << 20);
        while (nc < b->used + n) nc *= 2;
        char *nb = mmap(0, nc, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
        // only used between trees (reset), so no copy is needed for these probes
        if (b->buf) munmap(b->buf, b->cap);
        b->buf = nb; b->cap = nc; b->used = 0;
    }
    void *p = b->buf + b->used; b->used += n; return p;
}

// walk order: node, then right, then left (rust-5)
static N16 *mk16(Bump *b, int d) {
    N16 *t = bump(b, sizeof *t);
    if (d > 0) { t->r = mk16(b, d - 1); t->l = mk16(b, d - 1); } else { t->l = t->r = 0; }
    return t;
}
static long ck16(const N16 *t) { return t->l ? 1 + ck16(t->r) + ck16(t->l) : 1; }
// post-order: children first (Rig's ^bottom_up_tree(d-1) then the box)
static N16 *mk16p(Bump *b, int d) {
    N16 *l = 0, *r = 0;
    if (d > 0) { l = mk16p(b, d - 1); r = mk16p(b, d - 1); }
    N16 *t = bump(b, sizeof *t); t->l = l; t->r = r; return t;
}
static long ck16lr(const N16 *t) { return t->l ? 1 + ck16lr(t->l) + ck16lr(t->r) : 1; }
static volatile long sink;
static void drop16(N16 *t) { if (t->l) { drop16(t->l); drop16(t->r); } sink = (long)t; }

static int32_t mk8(N8 *pool, int32_t *at, int d) {
    int32_t i = (*at)++;
    if (d > 0) { int32_t r = mk8(pool, at, d - 1); int32_t l = mk8(pool, at, d - 1); pool[i].l = l; pool[i].r = r; }
    else pool[i].l = pool[i].r = -1;
    return i;
}
static long ck8(const N8 *pool, int32_t i) { return pool[i].l < 0 ? 1 : 1 + ck8(pool, pool[i].r) + ck8(pool, pool[i].l); }

// free list per thread, Rig plain's shape
typedef struct Blk { struct Blk *next; } Blk;
typedef struct { Blk *free; char pad0[120]; Bump carve; } Heap;
static __thread Heap *my_heap;
__attribute__((noinline)) static Heap *newheap(void) { Heap *h = aligned_alloc(128, sizeof *h); memset(h, 0, sizeof *h); my_heap = h; return h; }
__attribute__((noinline)) static void *fl_alloc(size_t n) {
    Heap *h = my_heap; if (!h) h = newheap();
    if (h->free) { Blk *b = h->free; h->free = b->next; return b; }
    if (h->carve.used + n > h->carve.cap) { h->carve.cap = 64 << 20; h->carve.buf = mmap(0, h->carve.cap, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0); h->carve.used = 0; }
    void *p = h->carve.buf + h->carve.used; h->carve.used += n; return p;
}
__attribute__((noinline)) static void fl_free(void *p) { Heap *h = my_heap; Blk *b = p; b->next = h->free; h->free = b; }
static __thread long drop_depth;
__attribute__((noinline)) static long *depth_slot(void) { return &drop_depth; }
// Rig plain: Tree returned by value; each child boxed after it is made
static N16 mkv(int d) {
    N16 t = {0, 0};
    if (d > 0) {
        N16 a = mkv(d - 1); N16 *l = fl_alloc(16); *l = a;
        N16 c = mkv(d - 1); N16 *r = fl_alloc(16); *r = c;
        t.l = l; t.r = r;
    }
    return t;
}
static void dropbox(N16 *p) {
    long *dd = depth_slot(); (*dd)++;
    if (p->r) dropbox(p->r);
    if (p->l) dropbox(p->l);
    (*dd)--;
    fl_free(p);
}

// nb: an arena bump behind a noinline call that reads the thread's heap (runtime.md M1)
__attribute__((noinline)) static void *nb_alloc(size_t n) {
    Heap *h = my_heap; if (!h) h = newheap();
    Bump *b = &h->carve; return bump(b, n);
}
static N16 *mknb(int d) {
    N16 *t = nb_alloc(16);
    if (d > 0) { t->r = mknb(d - 1); t->l = mknb(d - 1); } else t->l = t->r = 0;
    return t;
}

typedef struct { int depth, count; } Job;
static Job jobs[1024]; static int njobs; static atomic_int next_job;
static atomic_long sums[32];
static const char *mode;

static long run(int depth, int count, void **state) {
    long chk = 0;
    if (!strcmp(mode, "b16") || !strcmp(mode, "b16d") || !strcmp(mode, "b16p")) {
        Bump *b = *state; if (!b) { b = aligned_alloc(128, sizeof *b); memset(b, 0, sizeof *b); *state = b; }
        b->used = 0; bump(b, ((size_t)2 << depth) * sizeof(N16)); // sized once, never grown mid-tree
        for (int i = 0; i < count; i++) {
            b->used = 0;
            if (mode[3] == 'p') { N16 *t = mk16p(b, depth); chk += ck16lr(t); }
            else { N16 *t = mk16(b, depth); chk += ck16(t); if (mode[3] == 'd') drop16(t); }
        }
    } else if (!strcmp(mode, "b8")) {
        size_t need = ((size_t)2 << depth) * sizeof(N8);
        Bump *b = *state; if (!b) { b = aligned_alloc(128, sizeof *b); memset(b, 0, sizeof *b); *state = b; }
        b->used = 0; N8 *pool = bump(b, need);
        for (int i = 0; i < count; i++) { int32_t at = 0; int32_t r = mk8(pool, &at, depth); chk += ck8(pool, r); }
    } else if (!strcmp(mode, "fl")) {
        for (int i = 0; i < count; i++) { N16 t = mkv(depth); chk += ck16lr(&t); if (t.l) { dropbox(t.l); dropbox(t.r); } }
    } else if (!strcmp(mode, "nb")) {
        for (int i = 0; i < count; i++) {
            Heap *h = my_heap; if (!h) h = newheap();
            h->carve.used = 0; bump(&h->carve, ((size_t)2 << depth) * sizeof(N16));
            h->carve.used = 0; N16 *t = mknb(depth); chk += ck16(t);
        }
    }
    return chk;
}

static void *worker(void *arg) {
    void *state = 0; long k = (long)arg;
    for (;;) {
        int j = atomic_fetch_add(&next_job, 1);
        if (j >= njobs) break;
        atomic_fetch_add(&sums[jobs[j].depth], run(jobs[j].depth, jobs[j].count, &state));
    }
    (void)k; return 0;
}

static double now(void) { struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts); return ts.tv_sec + ts.tv_nsec * 1e-9; }

int main(int argc, char **argv) {
    mode = argv[1]; int threads = atoi(argv[2]); int n = argc > 3 ? atoi(argv[3]) : 21;
    int bydepth = getenv("SPLIT") && !strcmp(getenv("SPLIT"), "depth");
    int maxd = n < 6 ? 6 : n;
    double t0 = now();
    void *st = 0;
    long s = run(maxd + 1, 1, &st);
    printf("stretch tree of depth %d\t check: %ld\n", maxd + 1, s);
    double t1 = now();
    void *ll = 0; long lls = run(maxd, 1, &ll); // stands in for the long-lived tree (built and checked)
    double t2 = now();
    for (int d = 4; d <= maxd; d += 2) {
        int it = 1 << (maxd - d + 4);
        if (bydepth) { jobs[njobs++] = (Job){d, it}; continue; }
        int per = (it + 63) / 64;
        for (int left = it; left > 0; left -= per) jobs[njobs++] = (Job){d, left < per ? left : per};
    }
    if (getenv("ORDER") && !strcmp(getenv("ORDER"), "mix")) { // interleave depths: big and small trees at once
        Job tmp[1024]; int k = 0, used[1024] = {0};
        while (k < njobs) { int last = -1; for (int i = 0; i < njobs; i++) if (!used[i] && jobs[i].depth != last) { tmp[k++] = jobs[i]; used[i] = 1; last = jobs[i].depth; } }
        memcpy(jobs, tmp, sizeof(Job) * njobs);
    }
    if (getenv("ORDER") && !strcmp(getenv("ORDER"), "desc")) { for (int i = 0; i < njobs / 2; i++) { Job x = jobs[i]; jobs[i] = jobs[njobs - 1 - i]; jobs[njobs - 1 - i] = x; } }
    pthread_t th[64];
    for (long i = 0; i < threads; i++) pthread_create(&th[i], 0, worker, (void *)i);
    for (int i = 0; i < threads; i++) pthread_join(th[i], 0);
    double t3 = now();
    for (int d = 4; d <= maxd; d += 2) printf("%d\t trees of depth %d\t check: %ld\n", 1 << (maxd - d + 4), d, (long)sums[d]);
    printf("long lived tree of depth %d\t check: %ld\n", maxd, lls);
    fprintf(stderr, "%s split=%s threads=%d: stretch %.1f ms, long-lived %.1f ms, depths %.1f ms, total %.1f ms\n", mode, bydepth ? "depth" : "64", threads,
            (t1 - t0) * 1e3, (t2 - t1) * 1e3, (t3 - t2) * 1e3, (t3 - t0) * 1e3);
    return 0;
}
