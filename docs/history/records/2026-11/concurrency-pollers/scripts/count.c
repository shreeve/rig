// Counts the socket and poller system calls a process makes, per thread,
// by interposing libSystem's wrappers (DYLD_INSERT_LIBRARIES).
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <pthread.h>
#include <sys/event.h>
#include <sys/socket.h>
#include <sys/resource.h>
#include <sys/mman.h>
#include <poll.h>
#include <sys/uio.h>
#include <stdatomic.h>

#define MAXT 64
enum { RD, RD_AGAIN, WR, RECV, RECVFROM, SEND, SENDTO, KCHANGE, KLOOK, KLOOK_HIT, KWAIT, KWAIT_HIT, KEVENTS, KUSER, CSIG, CWAIT, EVR, EVW, POLL, MADV, MMAP, MUNMAP, MPROT, WRITEV, NK };
static const char *names[NK] = {"read", "read-EAGAIN", "write", "(recv)", "(recvfrom)", "(send)", "(sendto)", "kevent-change", "kevent-look", "kevent-look-hit", "kevent-wait", "kevent-wait-woke", "events", "user-kicks-seen", "cond-signal", "cond-wait", "ev-read", "ev-write", "poll", "madvise", "mmap", "munmap", "mprotect", "writev"};
static _Atomic unsigned long long cnt[MAXT][NK];
static _Atomic unsigned long long tids[MAXT];
static __thread int slot = -1;

static int me(void) {
  if (slot >= 0) return slot;
  uint64_t t; pthread_threadid_np(NULL, &t);
  for (int i = 0; i < MAXT; i++) {
    unsigned long long z = 0;
    if (atomic_load(&tids[i]) == t) return slot = i;
    if (atomic_compare_exchange_strong(&tids[i], &z, t)) return slot = i;
  }
  return slot = MAXT - 1;
}
static void add(int k) { atomic_fetch_add_explicit(&cnt[me()][k], 1, memory_order_relaxed); }
static int on = 0;

static ssize_t my_read(int fd, void *b, size_t n) { ssize_t r = read(fd, b, n); if (on) { add(RD); if (r < 0) add(RD_AGAIN);} return r; }
static ssize_t my_recv(int fd, void *b, size_t n, int fl) { ssize_t r = recv(fd, b, n, fl); if (on) { add(RECV); add(RD); if (r < 0) add(RD_AGAIN);} return r; }
static ssize_t my_recvfrom(int fd, void *b, size_t n, int fl, struct sockaddr *a, socklen_t *l) { ssize_t r = recvfrom(fd, b, n, fl, a, l); if (on) { add(RECVFROM); add(RD); if (r < 0) add(RD_AGAIN);} return r; }
static ssize_t my_write(int fd, const void *b, size_t n) { ssize_t r = write(fd, b, n); if (on && fd > 2) add(WR); return r; }
static ssize_t my_send(int fd, const void *b, size_t n, int fl) { ssize_t r = send(fd, b, n, fl); if (on) { add(WR); add(SEND); } return r; }
static ssize_t my_sendto(int fd, const void *b, size_t n, int fl, const struct sockaddr *a, socklen_t l) { ssize_t r = sendto(fd, b, n, fl, a, l); if (on) { add(WR); add(SENDTO); } return r; }
static int my_kevent(int kq, const struct kevent *ch, int nch, struct kevent *ev, int nev, const struct timespec *ts) {
  int r = kevent(kq, ch, nch, ev, nev, ts);
  if (!on) return r;
  if (nev == 0) { add(KCHANGE); return r; }
  int look = ts && ts->tv_sec == 0 && ts->tv_nsec == 0;
  add(look ? KLOOK : KWAIT);
  if (r > 0) { add(look ? KLOOK_HIT : KWAIT_HIT); for (int i = 0; i < r; i++) { add(KEVENTS); if (ev[i].filter == EVFILT_USER) add(KUSER); if (ev[i].filter == EVFILT_READ) add(EVR); if (ev[i].filter == EVFILT_WRITE) add(EVW);} }
  return r;
}
static int my_kevent64(int kq, const struct kevent64_s *ch, int nch, struct kevent64_s *ev, int nev, unsigned int fl, const struct timespec *ts) {
  int r = kevent64(kq, ch, nch, ev, nev, fl, ts);
  if (!on) return r;
  if (nev == 0) { add(KCHANGE); return r; }
  int look = (ts && ts->tv_sec == 0 && ts->tv_nsec == 0) || (fl & KEVENT_FLAG_IMMEDIATE);
  add(look ? KLOOK : KWAIT);
  if (r > 0) { add(look ? KLOOK_HIT : KWAIT_HIT); for (int i = 0; i < r; i++) { add(KEVENTS); if (ev[i].filter == EVFILT_USER) add(KUSER); if (ev[i].filter == EVFILT_READ) add(EVR); if (ev[i].filter == EVFILT_WRITE) add(EVW);} }
  return r;
}
static int my_pthread_cond_signal(pthread_cond_t *c) { if (on) add(CSIG); return pthread_cond_signal(c); }
static int my_pthread_cond_broadcast(pthread_cond_t *c) { if (on) add(CSIG); return pthread_cond_broadcast(c); }
static int my_pthread_cond_wait(pthread_cond_t *c, pthread_mutex_t *m) { if (on) add(CWAIT); return pthread_cond_wait(c, m); }
static int my_pthread_cond_timedwait(pthread_cond_t *c, pthread_mutex_t *m, const struct timespec *t) { if (on) add(CWAIT); return pthread_cond_timedwait(c, m, t); }
static int my_poll(struct pollfd *f, nfds_t n, int t) { if (on) add(POLL); return poll(f, n, t); }
static int my_madvise(void *a, size_t l, int adv) { if (on) add(MADV); return madvise(a, l, adv); }
static void *my_mmap(void *a, size_t l, int pr, int fl, int fd, off_t o) { if (on) add(MMAP); return mmap(a, l, pr, fl, fd, o); }
static int my_munmap(void *a, size_t l) { if (on) add(MUNMAP); return munmap(a, l); }
static int my_mprotect(void *a, size_t l, int pr) { if (on) add(MPROT); return mprotect(a, l, pr); }
static ssize_t my_writev(int fd, const struct iovec *v, int n) { if (on) { add(WRITEV); add(WR); } return writev(fd, v, n); }
#define I(n) __attribute__((used)) static struct { const void *a, *b; } in_##n __attribute__((section("__DATA,__interpose"))) = { (const void *)my_##n, (const void *)n };
I(read) I(recv) I(recvfrom) I(write) I(send) I(sendto) I(kevent) I(kevent64) I(pthread_cond_signal) I(pthread_cond_broadcast) I(pthread_cond_wait) I(pthread_cond_timedwait) I(poll) I(madvise) I(mmap) I(munmap) I(mprotect) I(writev)

static struct rusage r0;
static void onusr2(int sig);
__attribute__((constructor)) static void start(void) { getrusage(RUSAGE_SELF, &r0); on = 1; if (getenv("COUNT_SIGNAL")) signal(SIGUSR2, onusr2); }
static void dump(const char *mode) {
  struct rusage r1; getrusage(RUSAGE_SELF, &r1);
  const char *path = getenv("COUNT_OUT");
  FILE *f = path ? fopen(path, mode) : stderr;
  unsigned long long tot[NK] = {0};
  for (int i = 0; i < MAXT; i++) {
    if (!tids[i]) continue;
    int any = 0; for (int k = 0; k < NK; k++) any |= cnt[i][k] != 0;
    if (!any) continue;
    fprintf(f, "thread %2d:", i);
    for (int k = 0; k < NK; k++) { if (cnt[i][k]) fprintf(f, " %s=%llu", names[k], cnt[i][k]); tot[k] += cnt[i][k]; }
    fprintf(f, "\n");
  }
  fprintf(f, "total:");
  for (int k = 0; k < NK; k++) fprintf(f, " %s=%llu", names[k], tot[k]);
  fprintf(f, "\ncsw voluntary=%ld involuntary=%ld minflt=%ld majflt=%ld\n", r1.ru_nvcsw - r0.ru_nvcsw, r1.ru_nivcsw - r0.ru_nivcsw, r1.ru_minflt - r0.ru_minflt, r1.ru_majflt - r0.ru_majflt);
  if (path) fclose(f);
}
#include <signal.h>
static void onusr2(int sig) { (void)sig; dump("a"); }
__attribute__((destructor)) static void stop(void) { on = 0; if (!getenv("COUNT_SIGNAL")) dump("w"); }
