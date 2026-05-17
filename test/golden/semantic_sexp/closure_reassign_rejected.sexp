(module (sub main () _ (block (set fixed n _ 7) (set _ f _ (lambda (captures (cap_copy n)) _ _ (block n))) (set _ f _ (lambda (captures (cap_copy n)) _ _ (block (+ n 1)))) (call print (call f)))))
