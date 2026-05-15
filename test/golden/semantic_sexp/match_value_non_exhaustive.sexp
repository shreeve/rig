(module (enum Color red green blue) (sub main () _ (block (set _ c Color (enum_lit red)) (set _ x _ (match c (arm (enum_lit red) _ 1) (arm (enum_lit green) _ 2))))))
