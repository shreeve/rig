(module (sub main () _ (block (set packet (call make_packet)) (call send (move packet)) (call log (read packet)))))
