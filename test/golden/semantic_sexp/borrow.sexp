(module (sub main () _ (block (set user _ (call User (kwarg name "Steve"))) (set r _ (read user)) (call rename (write user)))))
