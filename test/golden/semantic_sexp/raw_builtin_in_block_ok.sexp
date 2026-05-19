(module (sub main () _ (block (set _ x _ 42) (raw_block (block (set _ y _ (builtin ptrCast x)) (call print y))))))
