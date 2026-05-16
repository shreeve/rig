(module (generic_type Box (T) (: value T)) (sub main () _ (block (set _ b (generic_inst Box Int) (call Box (kwarg value "hello"))) (call print (member b value)))))
