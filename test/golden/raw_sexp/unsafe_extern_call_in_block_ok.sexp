(module (extern _ puts (fun_type (String) Int)) (sub safe_puts ((: s String)) _ (block (unsafe_block (block (call puts s))))) (sub main () _ (block (call safe_puts "hi"))))
