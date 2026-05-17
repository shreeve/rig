(module (sub bump ((: c (generic_inst Cell Int))) _ (block (call (member c set) 1))) (sub main () _ (block (set _ c (generic_inst Cell Int) (call Cell (kwarg value 0))) (call bump c))))
