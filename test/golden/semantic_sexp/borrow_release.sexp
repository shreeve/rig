(module (sub main () _ (block (set _ user _ (call User (kwarg name "Steve"))) (set _ r _ (read user)) (drop r) (set _ w _ (write user)))))
