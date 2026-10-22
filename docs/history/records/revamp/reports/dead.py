p='src/emit.zig'
s=open(p).read()
def rep(old,new,count=1):
    global s
    assert s.count(old)==count, (old, s.count(old))
    s=s.replace(old,new)
rep('''    /// A match payload binding: the scrutinee it views. Moving it out
    /// consumes the scrutinee.
    scrutinee: ?SymbolId = null,
''','')
rep('''    /// Match payload (or catch-all) binding -> the scrutinee binding.
    views: std.AutoHashMapUnmanaged(SymbolId, SymbolId) = .empty,
''','')
rep('''        self.views.deinit(a);
''','')
rep('''            if (local.guard == .flag) {
                try self.w.print("{s} = false; ", .{local.flag});
            } else if (local.guard == .none) {
                // A match payload: the value leaves its scrutinee, and the
                // capture is a constant, so it is dropped from a copy.
                const flag = self.consumeFlag(local) orelse return self.w.writeAll("{}");
                try self.w.print("{s} = false; ", .{flag});
                if (kind == .value or kind == .optional) return self.w.print("rig.discard({s});", .{local.zig_name});
            }
''','''            if (local.guard == .flag) try self.w.print("{s} = false; ", .{local.flag});
''')
rep('''    /// The alive flag that must be cleared when `local`'s value leaves:
    /// its own, or its scrutinee's for a match payload binding.
    fn consumeFlag(self: *Emitter, local: *const Local) ?[]const u8 {
        if (local.guard == .flag) return local.flag;
        // A Copy payload is copied out; the scrutinee keeps its value.
        if (local.kind == null) return null;
        const s = local.scrutinee orelse return null;
        const scrut = self.localBySym(s) orelse return null;
        return if (scrut.guard == .flag) scrut.flag else null;
    }
''','''    /// The alive flag that must be cleared when `local`'s value leaves.
    fn consumeFlag(local: *const Local) ?[]const u8 {
        return if (local.guard == .flag) local.flag else null;
    }
''')
s=s.replace('self.consumeFlag(local)','consumeFlag(local)')
rep('''            var local = self.payloadLocal(b) orelse continue;
            local.scrutinee = null;
            const stored''','''            const local = self.payloadLocal(b) orelse continue;
            const stored''')
rep('''                var local = l;
                local.scrutinee = null;
                if (local.kind''','''                var local = l;
                if (local.kind''')
rep('''.kind = if (ty) |t| self.kindOf(t) else null, .scrutinee = self.usage.views.get(sym) };''','''.kind = if (ty) |t| self.kindOf(t) else null };''')
rep('''        try s.put(&s.e.usage.consumed, sym);
        // Moving a resource payload out consumes its scrutinee.
        if (s.e.usage.views.get(sym)) |scrut| {
            const ty = s.e.symType(sym) orelse return;
            if (s.e.kindOf(ty) != null) try s.put(&s.e.usage.consumed, scrut);
        }
''','''        try s.put(&s.e.usage.consumed, sym);
''')
rep('''            .@"??", .@"catch" => try s.consumeTail(sexp),
            .match => {
                const scrut = unborrowed(ir.Match.subject(sexp));
                const scrut_sym = if (scrut == .src) s.e.sema.symbolOf(scrut) else null;
                for (ir.Match.arms(sexp)) |arm| {
                    const pattern = ir.Arm.pattern(arm);
                    const binds: []const Sexp = if (pattern.isKind(.variant_pattern)) ir.VariantPattern.bindings(pattern) else (&pattern)[0..1];
                    if (scrut_sym) |ss| for (binds) |b| {
                        if (s.e.sema.symbolOf(b)) |bs| try s.e.usage.views.put(s.e.allocator, bs, ss);
                    };
                }
                try s.consumeTail(sexp);
            },
''','''            .@"??", .@"catch", .match => try s.consumeTail(sexp),
''')
rep('''        // A local read for nothing is discarded by address: Zig rejects
        // discarding a name that is used elsewhere.
        const e = unborrowed(sexp);
        if (e == .src) if (self.localOf(e)) |local| return self.w.print("_ = &{s};", .{local.zig_name});
''','')
open(p,'w').write(s)
