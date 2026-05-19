(module (struct User (: age Int)) (sub main () _ (block (set _ a _ (member (share (call User (kwarg age 5))) age)) (call print a))))
