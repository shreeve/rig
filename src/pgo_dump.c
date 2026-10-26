/* The profile writer of `rig build --pgo`'s instrumented build
   (src/pgo.zig), linked with LLVM's profile runtime
   (libclang_rt.profile) into a program that links no C library.

   LLVM's runtime writes its profile from an `atexit` handler, which a
   program without libc never runs: Zig's start code and Rig's runtime
   end the process with `exit_group`. So the runtime calls
   `__rig_pgo_dump` itself as the program ends (`writeProfile` in
   runtime.zig), and this file writes the profile with the runtime's
   own writer, `lprofWriteData`, value profiles included, by raw system
   calls. It also gives the runtime the few C functions it calls:
   `calloc` (the value profiles' site arrays) from an arena that is
   never freed, and the rest as stubs that do nothing.

   Each process writes RIG_PGO_DIR/raw-PID-N.profraw, the first N free,
   once. */

typedef unsigned long u64;
typedef long i64;

#ifndef RIG_PGO_DIR
#error "RIG_PGO_DIR names the directory the profiles go in"
#endif

static i64 sys4(i64 n, i64 a, i64 b, i64 c, i64 d) {
  i64 r;
#if defined(__x86_64__)
  register i64 r10 __asm__("r10") = d;
  __asm__ volatile("syscall" : "=a"(r) : "a"(n), "D"(a), "S"(b), "d"(c), "r"(r10) : "rcx", "r11", "memory");
#elif defined(__aarch64__)
  register i64 x8 __asm__("x8") = n;
  register i64 x0 __asm__("x0") = a;
  register i64 x1 __asm__("x1") = b;
  register i64 x2 __asm__("x2") = c;
  register i64 x3 __asm__("x3") = d;
  __asm__ volatile("svc 0" : "+r"(x0) : "r"(x8), "r"(x1), "r"(x2), "r"(x3) : "memory");
  r = x0;
#else
#error "rig build --pgo writes its profile on x86-64 and arm64 Linux"
#endif
  return r;
}

#if defined(__x86_64__)
enum { SYS_write = 1, SYS_close = 3, SYS_getpid = 39, SYS_openat = 257 };
#else
enum { SYS_write = 64, SYS_close = 57, SYS_getpid = 172, SYS_openat = 56 };
#endif
enum { AT_FDCWD = -100, O_WRONLY = 01, O_CREAT = 0100, O_EXCL = 0200 };

/* The runtime's C library. */
static char arena[1u << 28] __attribute__((aligned(64)));
static u64 used;
void *calloc(u64 n, u64 size) {
  u64 bytes = (n * size + 63) & ~63ul;
  u64 at = __atomic_fetch_add(&used, bytes, __ATOMIC_RELAXED);
  return at + bytes <= sizeof arena ? arena + at : 0;
}
void *malloc(u64 n) { return calloc(n, 1); }
void free(void *p) { (void)p; }
char *getenv(const char *name) { (void)name; return 0; }
long strtol(const char *s, char **end, int base) { (void)base; if (end) *end = (char *)s; return 0; }
void *stderr;
int __vfprintf_chk(void *f, int flag, const char *fmt, void *ap) { (void)f; (void)flag; (void)fmt; (void)ap; return 0; }
void __stack_chk_fail(void) { for (;;) __builtin_trap(); }

/* The runtime's writer: an array of pieces, each written or, without
   data, written as zeros. */
typedef struct { const void *data; u64 size; u64 count; int zeros; } Piece;
typedef struct Writer { unsigned (*write)(struct Writer *, Piece *, unsigned); void *context; } Writer;
void *lprofGetVPDataReader(void);
int lprofWriteData(Writer *, void *value_reader, int skip_names);

static int put(i64 fd, const char *p, u64 n) {
  while (n) {
    i64 w = sys4(SYS_write, fd, (i64)p, (i64)n, 0);
    if (w <= 0) return 1;
    p += w;
    n -= (u64)w;
  }
  return 0;
}

static const char zero_page[4096];
static unsigned writePieces(Writer *w, Piece *pieces, unsigned n) {
  i64 fd = (i64)w->context;
  for (unsigned i = 0; i < n; i++) {
    u64 bytes = pieces[i].size * pieces[i].count;
    if (pieces[i].data && !pieces[i].zeros) {
      if (put(fd, pieces[i].data, bytes)) return 1;
    } else {
      while (bytes) {
        u64 k = bytes < sizeof zero_page ? bytes : sizeof zero_page;
        if (put(fd, zero_page, k)) return 1;
        bytes -= k;
      }
    }
  }
  return 0;
}

static int decimal(char *at, u64 n) {
  char digits[24];
  int k = 0;
  do digits[k++] = (char)('0' + n % 10); while (n /= 10);
  for (int i = 0; i < k; i++) at[i] = digits[k - 1 - i];
  return k;
}

static int dumped;
void __rig_pgo_dump(void) {
  if (__atomic_exchange_n(&dumped, 1, __ATOMIC_SEQ_CST)) return;
  static const char dir[] = RIG_PGO_DIR "/raw-";
  char path[sizeof dir + 64];
  int k = 0;
  for (; dir[k]; k++) path[k] = dir[k];
  k += decimal(path + k, (u64)sys4(SYS_getpid, 0, 0, 0, 0));
  path[k++] = '-';
  for (u64 n = 0; n < 1000; n++) {
    int j = k + decimal(path + k, n);
    const char *ext = ".profraw";
    while (*ext) path[j++] = *ext++;
    path[j] = 0;
    i64 fd = sys4(SYS_openat, AT_FDCWD, (i64)path, O_WRONLY | O_CREAT | O_EXCL, 0644);
    if (fd == -17) continue; /* EEXIST: a process before this one had the PID */
    if (fd < 0) return;
    Writer w = { writePieces, (void *)fd };
    lprofWriteData(&w, lprofGetVPDataReader(), 0);
    sys4(SYS_close, fd, 0, 0, 0);
    return;
  }
}
