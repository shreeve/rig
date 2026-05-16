(module (struct Counter (: value Int)) (sub main () _ (block (set _ rc _ (share (call Counter (kwarg value 1)))) (set _ rc2 _ (clone rc)) (drop rc2) (drop rc) (call print "ok"))))
