(module (struct Node (: value Int)) (sub main () _ (block (set _ rc _ (share (call Node (kwarg value 7)))) (set _ w _ (weak rc)) (drop rc) (drop w) (call print "weak cycle ok"))))
