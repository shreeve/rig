(module (struct User (: name String)) (sub main () _ (block (set _ rc _ (share (call User (kwarg name "x")))) (set _ w _ (weak rc)) (set _ m _ (call (member w upgrade) 42)) (drop rc) (drop w))))
