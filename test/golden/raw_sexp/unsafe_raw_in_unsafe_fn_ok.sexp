(module (unsafe_decl (sub raw_op ((: x Int)) _ (block (set _ r _ (raw x)) (call print r)))) (sub main () _ (block (unsafe_block (block (call raw_op 42))))))
