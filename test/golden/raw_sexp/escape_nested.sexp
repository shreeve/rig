(module (fun bad () (borrow_read String) (block (set _ user _ (call User (kwarg name "Steve"))) (call View (kwarg name (read user))))))
