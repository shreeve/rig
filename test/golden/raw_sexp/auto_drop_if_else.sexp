(module (struct C (: v Int)) (sub main () _ (block (set _ rc _ (share (call C (kwarg v 7)))) (set _ cond _ true) (if cond (block (drop rc)) (block (call print (member rc v)))) (call print "done"))))
