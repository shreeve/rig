(module (enum Status (valued ok 0) (valued warn 1) (valued err 2)) (sub main () _ (block (set _ s Status (enum_lit ok)) (call print s))))
