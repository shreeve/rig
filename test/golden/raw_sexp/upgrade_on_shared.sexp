(module (struct User (: name String)) (sub main () _ (block (set _ rc _ (share (call User (kwarg name "x")))) (set _ m _ (call (member rc upgrade))) (drop rc))))
