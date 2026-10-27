extern void panic(void) __attribute__((noreturn));
struct S { unsigned *slots; };
long find(struct S *s, long start, long n, unsigned t) {
  for (long k = 0; k < n; k++) {
    long i = start + k;
    if ((unsigned long)i >= (1UL << 28)) panic();
    if (s->slots[i] == t) return k;
  }
  return -1;
}
long find2(struct S *s, long start, long n, unsigned t) {
  if (start >= 0 && n >= 0 && start <= (1L << 28) - n) {
    for (long k = 0; k < n; k++) {
      long i = start + k;
      if ((unsigned long)i >= (1UL << 28)) panic();
      if (s->slots[i] == t) return k;
    }
    return -1;
  }
  for (long k = 0; k < n; k++) {
    long i = start + k;
    if ((unsigned long)i >= (1UL << 28)) panic();
    if (s->slots[i] == t) return k;
  }
  return -1;
}
