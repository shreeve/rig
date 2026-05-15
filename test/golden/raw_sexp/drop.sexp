(module (sub main () _ (block (set _ user _ (call User (kwarg name "Steve"))) (drop user) (call print (read user)))))
