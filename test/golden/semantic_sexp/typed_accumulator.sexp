(module (fun sum_to ((: n Int)) Int (block (set _ sum _ 0) (set _ i _ 1) (while (<= i n) _ (block (set += sum _ i) (set += i _ 1))) sum)) (sub main () _ (block (call print (call sum_to 10)))))
