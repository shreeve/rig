(module (generic_type Box (T) (: value T)) (sub main () _ (block (set _ b (generic_inst Box String) (call Box (kwarg value "hi"))) (call print (member b value)))))
