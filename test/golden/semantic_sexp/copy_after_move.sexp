(module (fun consume ((: n Int)) Int (block n)) (sub main () _ (block (set _ n _ 1) (call consume (move n)) (call print n))))
