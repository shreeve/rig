(module (sub consume (f) _ (block (call print f))) (sub main () _ (block (set fixed n _ 3) (set _ f _ (lambda (captures (cap_copy n)) _ _ (block n))) (call consume f))))
