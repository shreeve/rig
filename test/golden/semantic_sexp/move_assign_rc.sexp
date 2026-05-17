(module (struct U (: v Int)) (sub main () _ (block (set _ rc _ (share (call U (kwarg v 1)))) (set _ rc2 _ (share (call U (kwarg v 2)))) (set move rc2 _ rc) (call print (member rc2 v)))))
