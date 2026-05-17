(module (struct User (: name String)) (sub main () _ (block (set _ c (generic_inst Cell User) (call Cell (kwarg value (call User (kwarg name "x"))))))))
