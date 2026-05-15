(module (enum Color red green) (sub main () _ (block (set _ c Color (enum_lit red)) (match c (arm (enum_lit red) _ (call print "R")) (arm (enum_lit purple) _ (call print "P"))))))
