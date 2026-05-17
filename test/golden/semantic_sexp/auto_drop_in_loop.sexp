(module (struct C (: v Int)) (sub main () _ (block (set _ i _ 0) (while (< i 3) _ (block (set _ rc _ (share (call C (kwarg v i)))) (call print (member rc v)) (set += i _ 1))) (call print "done"))))
