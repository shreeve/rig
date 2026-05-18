(module (unsafe_decl (sub low_level () _ (block (call print 1)))) (unsafe_decl (sub high_level () _ (block (call low_level)))) (sub main () _ (block (unsafe_block (block (call high_level))))))
