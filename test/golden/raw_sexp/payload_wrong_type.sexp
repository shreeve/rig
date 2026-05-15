(module (enum Shape (variant circle ((: radius Int)))) (sub main () _ (block (set _ s Shape (call (enum_lit circle) (kwarg radius "nope"))))))
