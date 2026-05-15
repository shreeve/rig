(module (errors NetworkError timeout refused reset) (sub main () _ (block (set _ e NetworkError (enum_lit timeout)) (call print e))))
