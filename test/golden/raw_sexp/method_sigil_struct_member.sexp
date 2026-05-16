(module (struct S (: name String) (read x)) (sub main () _ (block (set _ s _ (call S (kwarg name "a") (kwarg x 5))) (call print (member s name)))))
