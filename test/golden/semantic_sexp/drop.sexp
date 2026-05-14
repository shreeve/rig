(module (sub main () _ (block (set user (call User (kwarg name "Steve"))) (drop user) (call print (read user)))))
