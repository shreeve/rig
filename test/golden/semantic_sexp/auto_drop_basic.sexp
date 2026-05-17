(module (struct Counter (: value Int)) (sub main () _ (block (set _ rc _ (share (call Counter (kwarg value 7)))) (call print (member rc value)))))
