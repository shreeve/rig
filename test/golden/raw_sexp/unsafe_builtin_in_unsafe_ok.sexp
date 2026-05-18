(module (sub main () _ (block (set _ x _ 42) (unsafe_block (block (set _ y _ (builtin ptrCast x)) (call print y))))))
