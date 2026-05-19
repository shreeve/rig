(module (struct File (: fd Int) (drop_decl ((: self (borrow_write File)) (: extra Int)) (block (call print (+ (member self fd) extra))))))
