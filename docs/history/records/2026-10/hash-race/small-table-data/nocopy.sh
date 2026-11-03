#!/bin/sh
# Patch an emitted package (RIG_OUT_DIR) so the blocking pool does not copy a call's
# []const u8 arguments: measurement only, it drops the cancel safety the copy gives.
sed -i '' 's/if (stoppable) ownArgs(&c.args);/if (false) ownArgs(\&c.args);/; s/if (stoppable) freeArgs(&self.args);/if (false) freeArgs(\&self.args);/' "$1/rig/sched.zig"
