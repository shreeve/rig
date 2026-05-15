(module (enum Shape (variant triangle ((: a Int) (: b Int)))) (sub main () _ (block (set _ s Shape (call (enum_lit triangle) (kwarg a 1))))))
