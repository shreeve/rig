(module (struct User (: name String)) (sub takeVec ((: v (generic_inst Vec User))) _ (block (call print "placeholder"))) (sub main () _ (block (call print "hi"))))
