(module (sub main () _ (block (set _ x _ (if true (block 1) (block 2))) (set _ y _ (if (> x 0) (block 100) (block (neg 100)))) (call print x) (call print y))))
