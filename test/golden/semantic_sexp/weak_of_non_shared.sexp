(module (struct User (: name String)) (sub main () _ (block (set _ u _ (call User (kwarg name "x"))) (set _ w _ (weak u)))))
