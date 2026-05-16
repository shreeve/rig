(module (generic_type Box (T) (: value T)) (sub main () _ (block (set _ b _ (call Box (kwarg value 5))) (call print (member b value)))))
