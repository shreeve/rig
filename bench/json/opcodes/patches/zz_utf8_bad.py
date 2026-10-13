"""Mutation check only: utf8_kl whose check accepts everything; optest must fail."""
import _utf8
_utf8.KL = _utf8.KL.replace("return ((third | fourth) & @as(OpV, @splat(0x80))) ^ sc;", "_ = third; _ = fourth; _ = sc; return @splat(0);")
patch = _utf8.make()
