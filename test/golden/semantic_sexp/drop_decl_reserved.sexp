(module (struct File (: fd Int) (drop_decl ((: self (borrow_write File))) (block (raw_block (block (call print (member self fd))))))))
