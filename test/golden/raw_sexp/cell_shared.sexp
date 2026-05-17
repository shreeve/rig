(module (sub main () _ (block (set _ rc (shared (generic_inst Cell Int)) (share (call Cell (kwarg value 0)))) (call (member rc set) 5) (call print (call (member rc get))))))
