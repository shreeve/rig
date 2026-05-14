(module (sub main () _ (block (set packet _ (call make_packet)) (call send (move packet)) (call log (read packet)))))
