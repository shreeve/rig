(module (sub stub ((: cb (shared Closure))) _ (block (call print "never reached"))) (sub main () _ (block (call print "hi"))))
