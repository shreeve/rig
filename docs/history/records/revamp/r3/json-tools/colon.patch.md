# colon: the `:` after a key decided with one read (std.json experiment, 2026-10-16)

In `Doc.key` (std/json.rig), after `return -1 if end < 0` and before `i = skip_space(src, end)`, add:

    # In compact JSON the `:` follows the key at once: one read decides.
    return skip_space(src, end + 1) if end < src.len and src[end] == COLON

Timed against main (honest harness), it passes the speed rule on both machines on its own:
- Mac (cpuq exclusive window): github 3.0% faster, citm 2.0%, the rest 0.7-1.2% faster, nothing slower.
- x86 (pup, `cpuq lease pup-bench --exclusive`, outside work 2.6 CPUs): twitterescaped 6.2% faster, github 2.9%, citm 2.8%, gsoc 2.3%, twitter 1.0%, canada 0.5%.

It does NOT combine with strfast today: with both, Rig's inliner's expanded-size cap pushes `key` out of line (`pub fn key`) and the pair loses (citm, gsoc, github ~2% more instructions). Retry it combined, with `inline fun key`, once inline2 (#246) lands.
