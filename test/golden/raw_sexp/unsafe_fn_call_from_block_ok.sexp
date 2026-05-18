(module (unsafe_decl (sub raw_op () _ (block (call print 1)))) (sub safe_wrapper () _ (block (unsafe_block (block (call raw_op))))) (sub main () _ (block (call safe_wrapper))))
