(module (fun may_fail () (error_union Int) (block (return 42))) (sub main () _ (block (set _ r _ (try_block (block (propagate (call may_fail))) (catch_block e (block 0)))) (call print r))))
