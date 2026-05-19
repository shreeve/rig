(module (struct File (: fd Int) (drop_decl ((: self (borrow_read File))) (block (call print (member self fd))))))
