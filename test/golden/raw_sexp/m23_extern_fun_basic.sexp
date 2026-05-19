(module (extern_fun puts ((: s String)) Int) (sub safe_puts ((: s String)) _ (block (raw_block (block (call puts s))))) (sub main () _ (block (call safe_puts "hello, m23"))))
