(module (struct User (: age Int)) (fun make_user () (shared User) (block (return (share (call User (kwarg age 5)))))) (sub main () _ (block (set _ a _ (member (call make_user) age)) (call print a))))
