(module (struct User (: name String) (: age Int)) (sub main () _ (block (set _ u _ (call User (kwarg name "Steve") (kwarg lol 30))))))
