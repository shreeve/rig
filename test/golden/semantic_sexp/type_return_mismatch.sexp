(module (fun bad () Int (block "not an int")) (sub main () _ (block (set _ x _ (call bad)) (call print x))))
