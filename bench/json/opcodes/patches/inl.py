"""The runtime's mask helpers (maskFirst, maskBits, maskAny, maskAll) made
`inline`, so a mask reaches its reduction in registers even where LLVM
would keep the helper a call. Combine with another patch: ws_cmp+inl."""


def patch(s):
    return s


def patch_runtime(r):
    for name in ("maskFirst", "maskBits", "maskAny", "maskAll"):
        old = "pub fn %s(" % name
        assert r.count(old) == 1, name
        r = r.replace(old, "pub inline fn %s(" % name)
    return r
