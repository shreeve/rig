(module (fun bad () (? String) (block (= user (call User (pair name "Steve"))) (read (. user name)))) (fun name ((: user (? User))) (? String) (block (read (. user name)))))
