(module (fun pick ((: c Bool)) Int (block (if c (block 10) (block 20)))) (sub main () _ (block (call print (call pick true)) (call print (call pick false)))))
