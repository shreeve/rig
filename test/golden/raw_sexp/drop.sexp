(module (sub main () _ (block (= user (call User (pair name "Steve"))) (drop user) (call print (read user)))))
