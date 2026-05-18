(module (pub (unsafe_decl (sub a () _ (block (call print 1))))) (unsafe_decl (pub (sub b () _ (block (call print 2))))) (sub main () _ (block (unsafe_block (block (call a) (call b))))))
