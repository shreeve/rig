(module (sub main () _ (block (= packet (call make_packet)) (call send (move packet)) (call log (read packet)))))
