(module (fun loadUser ((: id U64)) (error_union User) (block (call User (kwarg name "Steve")))) (sub main () _ (block (set _ x _ (call loadUser 1)) (call print x))))
