"""For src:wsbits*: skip_ws_run out of line (noinline), its entry inline,
as an inlining rule could choose; it keeps `key` and `document` small."""


def patch(s):
    old = "    pub inline fn skip_ws_run("
    assert s.count(old) == 1
    return s.replace(old, "    pub noinline fn skip_ws_run(")
