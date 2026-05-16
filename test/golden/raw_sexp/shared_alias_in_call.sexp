(module (struct Box (: value Int)) (sub use_rc ((: rc (shared Box))) _ (block (drop rc))) (sub main () _ (block (set _ rc _ (share (call Box (kwarg value 1)))) (call use_rc rc) (drop rc))))
