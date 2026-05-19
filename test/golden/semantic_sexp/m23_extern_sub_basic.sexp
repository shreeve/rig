(module (extern_sub log_msg ((: msg String))) (sub safe_log ((: msg String)) _ (block (raw_block (block (call log_msg msg))))) (sub main () _ (block (call safe_log "ping"))))
