(module (sub main () _ (block (set fixed n _ 5) (set _ f _ (lambda (captures (cap_copy n)) _ _ (block (+ n 1)))) (set _ g _ f) (call g))))
