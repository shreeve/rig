(module (sub main () _ (block (set _ x _ 7) (unsafe_block (block (set _ r _ (raw x)) (call print r))))))
