(module (struct Box (: value Int)) (sub main () _ (block (set _ rc _ (share (call Box (kwarg value 1)))) (set _ rc2 _ rc) (drop rc2) (drop rc))))
