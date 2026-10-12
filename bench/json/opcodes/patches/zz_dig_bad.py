"""Mutation check only: dig16 that drops the lowest digit lane; optest must fail."""
import _dig
_dig.SIXTEEN = _dig.SIXTEEN.replace("return @as(u64, r[0]) *% 100000000 +% @as(u64, r[1]);", "return @as(u64, r[0]) *% 100000000 +% @as(u64, r[1]) / 10 * 10;")
patch = _dig.make()
