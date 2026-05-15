(module (sub main () _ (block (set _ x _ 5) (match x (arm (range_pattern 1 3) _ (call print "low")) (arm (range_pattern 4 6) _ (call print "mid")) (arm other _ (call print "high"))))))
