(module (fun consume ((: a Int)) Int (block a)) (sub main () _ (block (set _ x _ (call consume "nope")) (call print x))))
