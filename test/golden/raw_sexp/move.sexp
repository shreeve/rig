(module (sub main () _ (block (set _ packet _ (call make_packet)) (call send (move packet)) (call log (read packet)))))
