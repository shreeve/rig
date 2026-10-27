extern void panic(void) __attribute__((noreturn));
extern void tick(void) __attribute__((cold));
struct S { unsigned *slots; };
extern int turns;
long find_after(struct S *restrict s, long start, long n, unsigned t) {
  for (long k = 0; k < n; k++) {
    long i = start + k;
    if ((unsigned long)i >= (1UL << 28)) panic();
    unsigned *b = s->slots;
    if (b[i] == t) return k;
    if (--turns == 0) tick();
  }
  return -1;
}
long find_before(struct S *restrict s, long start, long n, unsigned t) {
  for (long k = 0; k < n; k++) {
    unsigned *b = s->slots;
    long i = start + k;
    if ((unsigned long)i >= (1UL << 28)) panic();
    if (b[i] == t) return k;
    if (--turns == 0) tick();
  }
  return -1;
}
