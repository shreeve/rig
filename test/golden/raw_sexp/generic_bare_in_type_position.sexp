(module (generic_type Box (T) (: value T)) (sub main () _ (block (set _ x Box (call Box (kwarg value 5))) (call print (member x value)))))
