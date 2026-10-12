"""Mutation check only: esc_copy16 that keeps one byte too many; optest must fail."""
from _esc import make, COPY16
patch = make(COPY16.replace("l.items.len += @intCast(k);", "l.items.len += @intCast(k + 1);"))
