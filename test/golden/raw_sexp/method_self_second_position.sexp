(module (struct User (: name String) (fun bad ((: other Int) (read self)) Int (block other))) (sub main () _ (block (set _ u _ (call User (kwarg name "x"))) (call print (call (member u bad) 42)))))
