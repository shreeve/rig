# Keywords in the grammar

Branch keywords (2 commits on cbed98f8), from the Nexus prototype.

1. Reserved words become lexer rules; the keywords StaticStringMap in src/rig.zig is gone (new, of stay in the wrapper).
2. @keywords ctx unique from static plus @as IDENT = [ctx!] delete isStructUnique, isResultFrom, fun_arrow and the static-after-from check. INTERNALS gains a Keywords section; rig tokens prints ident for unique/from/static.

Gates after each step: nexus check 0 conflicts (736 states); build; test/run --delta 3205 passed, 0 failed, 3 pending; equiv vs cbed98f8 12631 programs, 0 differ (the three accepted message changes are not in the corpus).
