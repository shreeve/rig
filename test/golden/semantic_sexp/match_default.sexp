(module (enum Color red green blue) (sub main () _ (block (set _ c Color (enum_lit red)) (match c (arm (enum_lit red) _ (call print "red")) (arm other _ (call print "not red"))))))
