(module (struct User (: name String) (fun greet () String (block "hi"))) (sub main () _ (block (call print (call (member User greet))))))
