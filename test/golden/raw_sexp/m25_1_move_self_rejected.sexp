(module (struct Owner (: cell (shared (generic_inst Cell Int))) (drop_decl ((: self (borrow_write Owner))) (block (set _ other _ (move self))))))
