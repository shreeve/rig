(module (struct User (: name String) (fun greet (self) String (block "hi"))) (sub main () _ (block (set _ u _ (call User (kwarg name "Steve"))) (call print (call (member u greet))))))
