(module (sub main () _ (block (set _ v (generic_inst Vec Int) (call Vec)) (call (member (write v) push) 1) (for ptr x _ v (block (call print x))))))
