(module (sub main () _ (block (set user _ (call User (kwarg name "Steve"))) (drop user) (call print (read user)))))
