## webpack (full c1; checks = 5.8% of cycles)

std Map/Set/Ordered (innermost frame in the tables): 2.23% of all weighted check branches (zig.integerOverflow 1.58, zig.integerOutOfBounds 0.46, zig.outOfBounds 0.09, zig.incorrectAlignment 0.08, zig.startGreaterThanEnd 0.02), ~0.14% of cycles; counted inside the rows below by their caller

| kind | share of all | share of live | ~% of cycles |
|---|---:|---:|---:|
| H1 handle: index by an id (a Table store covers) | 18.81% | 20.8% | 1.21% |
| H2 handle: Table length read in check_id (lenHeld misses Table) | 10.65% | 11.8% | 0.68% |
| Z runtime and Zig std | 9.71% | 10.8% | 0.62% |
| H1 handle: index by an id (other List) | 9.23% | 10.2% | 0.59% |
| (not run) b-built | 9.21% |  | ~0 |
| H3 handle: inside a record (offset/slice; Table alone does not cover) | 8.02% | 8.9% | 0.52% |
| L List/slice index in checker | 7.02% | 7.8% | 0.45% |
| C conversions/overflow elsewhere (checker) | 5.72% | 6.3% | 0.37% |
| O other (ast index) | 4.59% | 5.1% | 0.29% |
| F front-end rule kinds: std | 2.95% | 3.3% | 0.19% |
| F front-end rule kinds: a | 2.80% | 3.1% | 0.18% |
| F front-end rule kinds: e | 1.38% | 1.5% | 0.09% |
| F front-end rule kinds: a+ | 1.31% | 1.5% | 0.08% |
| F front-end rule kinds: c2r | 1.00% | 1.1% | 0.06% |
| C conversions/overflow elsewhere (ast) | 0.99% | 1.1% | 0.06% |
| F front-end rule kinds: hash | 0.79% | 0.9% | 0.05% |
| R conversions/overflow in relation code | 0.79% | 0.9% | 0.05% |
| F front-end rule kinds: b+ | 0.75% | 0.8% | 0.05% |
| O other (ast slice) | 0.55% | 0.6% | 0.04% |
| F front-end rule kinds: c2n | 0.55% | 0.6% | 0.04% |
| (not run) cold | 0.48% |  | ~0 |
| F front-end rule kinds: ctr | 0.38% | 0.4% | 0.02% |
| O other (lexer index) | 0.33% | 0.4% | 0.02% |
| F front-end rule kinds: c2p | 0.32% | 0.4% | 0.02% |
| C conversions/overflow elsewhere (parser) | 0.30% | 0.3% | 0.02% |
| F front-end rule kinds: data | 0.28% | 0.3% | 0.02% |
| C conversions/overflow elsewhere (core) | 0.19% | 0.2% | 0.01% |
| O other (core index) | 0.16% | 0.2% | 0.01% |
| O other (parser index) | 0.12% | 0.1% | 0.01% |
| O other (tspath slice) | 0.08% | 0.1% | 0.00% |
| C conversions/overflow elsewhere (lexer) | 0.07% | 0.1% | 0.00% |
| O other (tspath index) | 0.07% | 0.1% | 0.00% |
| O other (parser slice) | 0.06% | 0.1% | 0.00% |
| L List/slice index in binder | 0.06% | 0.1% | 0.00% |
| O other (lexer slice) | 0.04% | 0.0% | 0.00% |
| C conversions/overflow elsewhere (tspath) | 0.04% | 0.0% | 0.00% |
| C conversions/overflow elsewhere (compiler) | 0.04% | 0.0% | 0.00% |
| O other (checker len) | 0.02% | 0.0% | 0.00% |
| C conversions/overflow elsewhere (stringutil) | 0.02% | 0.0% | 0.00% |
| L List/slice index in compiler | 0.02% | 0.0% | 0.00% |
| O other (jsnum slice) | 0.01% | 0.0% | 0.00% |
| O other (diagnostics slice) | 0.01% | 0.0% | 0.00% |
| O other (stringutil index) | 0.01% | 0.0% | 0.00% |
| O other (diagnostics index) | 0.01% | 0.0% | 0.00% |
| C conversions/overflow elsewhere (diagnostics) | 0.01% | 0.0% | 0.00% |
| O other (parser zbounds) | 0.01% | 0.0% | 0.00% |
| O other (module index) | 0.01% | 0.0% | 0.00% |
| C conversions/overflow elsewhere (jsnum) | 0.01% | 0.0% | 0.00% |
| O other (jsnum index) | 0.01% | 0.0% | 0.00% |
| C conversions/overflow elsewhere (binder) | 0.00% | 0.0% | 0.00% |
| C conversions/overflow elsewhere (printer) | 0.00% | 0.0% | 0.00% |
| C conversions/overflow elsewhere (collections) | 0.00% | 0.0% | 0.00% |
| O other (collections index) | 0.00% | 0.0% | 0.00% |
| O other (packagejson index) | 0.00% | 0.0% | 0.00% |
| O other (core slice) | 0.00% | 0.0% | 0.00% |
| O other (vfsmatch index) | 0.00% | 0.0% | 0.00% |
| C conversions/overflow elsewhere (packagejson) | 0.00% | 0.0% | 0.00% |
| L List/slice index in declarations | 0.00% | 0.0% | 0.00% |
| O other (module slice) | 0.00% | 0.0% | 0.00% |
| O other (printer zbounds) | 0.00% | 0.0% | 0.00% |

- **H1 handle: index by an id (a Table store covers)**: `ast.Ast.kind@ast.zig:530 | return self.recs.at(n.id).kind;` 5.16; `ast.Ast.parent@ast.zig:567 | return (__rig_rt_112: { var __rig_v_112 = as_node(self.recs.at(n.id).parent); _ = &__rig_v_112; break :__rig_r` 1.81; `ast.Ast.word_node@ast.zig:1029 | return (__rig_rt_203: { var __rig_v_203 = as_node(self.words.at(@as(i64, @intCast(@as(u32, self.recs.at(n.id).` 1.45
- **H2 handle: Table length read in check_id (lenHeld misses Table)**: `checker.Checker.checker_symbol@checker.zig:2627 | rig.rt(check_id((@as(i64, @intCast(@as(u32, s))) - @as(i64, @intCast(@as(u32, self.binder_syms)))) - 1, rig.le` 3.15; `compiler.Ids.binder_sym@compiler.zig:4534 | rig.rt(check_id(@as(i64, @intCast(@as(u32, s))), rig.lenOf(self.binder)));` 3.10; `compiler.Ids.node_id@compiler.zig:4513 | rig.rt(check_id(@as(i64, @intCast(@as(u32, file))) - 1, rig.lenOf(self.node_base)));` 1.89
- **Z runtime and Zig std**: `rig.runtime.slice@runtime.zig:5275 | ` 0.65; `checker.Layout.home@checker.zig:88341 | return @as(i64, @intCast(@as(u64, @as(u64, @as(u64, @as(u64, @intCast(@as(u32, name)))) *% 0x9E3779B97F4A7C15)` 0.58; `ast.BigTable.home@ast.zig:18141 | return @as(i64, @intCast(@as(u64, @as(u64, @as(u64, @as(u64, @intCast(@as(u32, name)))) *% 0x9E3779B97F4A7C15)` 0.40
- **H1 handle: index by an id (other List)**: `checker.Layout.get@checker.zig:88356 | const s: u32 = self.slots.at(i);` 0.48; `checker.Layout.get@checker.zig:88360 | if (self.names.at(@as(i64, @intCast(@as(u32, s))) - 1) == name) {` 0.48; `ast.Binding.declaration_of@ast.zig:18719 | return self.more_nodes.at((@as(i64, @intCast(@as(u32, self.symbol_extras.at(@as(i64, @intCast(@as(u32, extra))` 0.47
- **H3 handle: inside a record (offset/slice; Table alone does not cover)**: `ast.Ast.word_node@ast.zig:1029 | return (__rig_rt_203: { var __rig_v_203 = as_node(self.words.at(@as(i64, @intCast(@as(u32, self.recs.at(n.id).` 3.08; `ast.Ast.word_list@ast.zig:1039 | return (__rig_rt_204: { var __rig_v_204 = as_list(self.words.at(@as(i64, @intCast(@as(u32, self.recs.at(n.id).` 1.20; `ast.Ast.nodes@ast.zig:574 | return rig.slice(self.list_nodes.items(), @as(i64, @intCast(@as(u32, r.start))), @as(i64, @intCast(@as(u32, r.` 0.97
- **L List/slice index in checker**: `checker.Checker.synthetic_index@checker.zig:86475 | if (@as(i64, @intCast(@as(u32, n.node.id))) <= rig.rt(self.program.*.files.constSlot(@as(i64, @as(i64, @intCas` 0.85; `checker.Checker.node_kind@checker.zig:86503 | return self.synthetic_nodes.atProven(k, .lower).kind;` 0.44; `checker.Checker.node_kind@checker.zig:86505 | return rig.rt(self.program.*.files.constSlot(@as(i64, @as(i64, @intCast(@as(u32, n.file)))) -% 1).*.ast.kind(n` 0.42
- **C conversions/overflow elsewhere (checker)**: `checker.Checker.flow_memo_effect_sum@checker.zig:38205 | return (((((((((((@as(i64, @intCast(@as(u32, self.type_count))) + @as(i64, @intCast(@as(u32, self.signature_co` 0.93; `checker.Checker.union_front_state@checker.zig:5552 | const effects: i64 = ((((((((((@as(i64, @intCast(@as(u32, self.type_count))) + @as(i64, @intCast(@as(u32, self` 0.46; `checker.node_ref@checker.zig:97625 | return NodeRef{ .file = @as(u32, @intCast(@as(u64, @intCast(@as(i64, f + 1))))), .node = n };` 0.21
- **O other (ast index)**: `ast.Ast.text@ast.zig:0 | ` 0.55; `ast.BigTable.place_of@ast.zig:18166 | const s: u32 = self.slots.at(i);` 0.38; `ast.Binding.table_get_unmasked@ast.zig:18392 | return rig.rt(self.big_tables.constSlot(@as(i64, @intCast(@as(u32, h.start)))).*.get(name));` 0.37
- **F front-end rule kinds: std**: `__rig_std_prelude.Set(checker.CacheKey).take@__rig_std_prelude.zig:288 | var key = self.t.take(k);` 0.20; `__rig_std_prelude.Set(u32).add@__rig_std_prelude.zig:278 | const added: bool = self.t.add(rig.take(&__rig_alive_k, k));` 0.19; `__rig_std_utf8.multi_after@__rig_std_utf8.zig:38 | const c1: u8 = rig.at(s, i + 1);` 0.18

## typeorm (full c1; checks = 5.4% of cycles)

std Map/Set/Ordered (innermost frame in the tables): 2.30% of all weighted check branches (zig.integerOverflow 1.66, zig.integerOutOfBounds 0.44, zig.incorrectAlignment 0.10, zig.outOfBounds 0.09, zig.startGreaterThanEnd 0.01), ~0.14% of cycles; counted inside the rows below by their caller

| kind | share of all | share of live | ~% of cycles |
|---|---:|---:|---:|
| H1 handle: index by an id (a Table store covers) | 18.59% | 20.6% | 1.11% |
| Z runtime and Zig std | 11.37% | 12.6% | 0.68% |
| H2 handle: Table length read in check_id (lenHeld misses Table) | 10.18% | 11.3% | 0.61% |
| (not run) b-built | 9.38% |  | ~0 |
| H3 handle: inside a record (offset/slice; Table alone does not cover) | 8.13% | 9.0% | 0.49% |
| H1 handle: index by an id (other List) | 8.13% | 9.0% | 0.49% |
| L List/slice index in checker | 7.20% | 8.0% | 0.43% |
| C conversions/overflow elsewhere (checker) | 5.45% | 6.1% | 0.33% |
| O other (ast index) | 4.32% | 4.8% | 0.26% |
| F front-end rule kinds: std | 3.08% | 3.4% | 0.18% |
| F front-end rule kinds: a | 2.88% | 3.2% | 0.17% |
| F front-end rule kinds: a+ | 1.32% | 1.5% | 0.08% |
| F front-end rule kinds: e | 1.29% | 1.4% | 0.08% |
| F front-end rule kinds: b+ | 1.13% | 1.3% | 0.07% |
| F front-end rule kinds: c2r | 0.95% | 1.0% | 0.06% |
| C conversions/overflow elsewhere (ast) | 0.92% | 1.0% | 0.06% |
| F front-end rule kinds: hash | 0.92% | 1.0% | 0.06% |
| R conversions/overflow in relation code | 0.86% | 0.9% | 0.05% |
| F front-end rule kinds: c2n | 0.54% | 0.6% | 0.03% |
| (not run) cold | 0.50% |  | ~0 |
| F front-end rule kinds: ctr | 0.43% | 0.5% | 0.03% |
| O other (ast slice) | 0.35% | 0.4% | 0.02% |
| O other (tspath slice) | 0.33% | 0.4% | 0.02% |
| F front-end rule kinds: c2p | 0.32% | 0.4% | 0.02% |
| O other (lexer index) | 0.29% | 0.3% | 0.02% |
| O other (tspath index) | 0.24% | 0.3% | 0.01% |
| C conversions/overflow elsewhere (parser) | 0.17% | 0.2% | 0.01% |
| C conversions/overflow elsewhere (tspath) | 0.17% | 0.2% | 0.01% |
| O other (parser index) | 0.10% | 0.1% | 0.01% |
| C conversions/overflow elsewhere (compiler) | 0.07% | 0.1% | 0.00% |
| L List/slice index in binder | 0.06% | 0.1% | 0.00% |
| O other (parser slice) | 0.06% | 0.1% | 0.00% |
| F front-end rule kinds: data | 0.06% | 0.1% | 0.00% |
| C conversions/overflow elsewhere (lexer) | 0.05% | 0.1% | 0.00% |
| O other (module index) | 0.04% | 0.0% | 0.00% |
| L List/slice index in compiler | 0.03% | 0.0% | 0.00% |
| O other (lexer slice) | 0.02% | 0.0% | 0.00% |
| C conversions/overflow elsewhere (module) | 0.02% | 0.0% | 0.00% |
| O other (checker len) | 0.02% | 0.0% | 0.00% |
| O other (jsnum slice) | 0.02% | 0.0% | 0.00% |
| O other (packagejson index) | 0.01% | 0.0% | 0.00% |
| C conversions/overflow elsewhere (c) | 0.01% | 0.0% | 0.00% |
| O other (module slice) | 0.01% | 0.0% | 0.00% |
| O other (core slice) | 0.01% | 0.0% | 0.00% |
| C conversions/overflow elsewhere (jsnum) | 0.01% | 0.0% | 0.00% |
| O other (jsnum index) | 0.01% | 0.0% | 0.00% |
| O other (stringutil index) | 0.01% | 0.0% | 0.00% |
| C conversions/overflow elsewhere (binder) | 0.01% | 0.0% | 0.00% |
| C conversions/overflow elsewhere (collections) | 0.00% | 0.0% | 0.00% |
| O other (collections index) | 0.00% | 0.0% | 0.00% |
| O other (parser zbounds) | 0.00% | 0.0% | 0.00% |
| C conversions/overflow elsewhere (core) | 0.00% | 0.0% | 0.00% |
| C conversions/overflow elsewhere (vfs) | 0.00% | 0.0% | 0.00% |
| O other (diagnosticwriter index) | 0.00% | 0.0% | 0.00% |
| C conversions/overflow elsewhere (execute) | 0.00% | 0.0% | 0.00% |
| O other (vfsmatch index) | 0.00% | 0.0% | 0.00% |
| O other (vfs slice) | 0.00% | 0.0% | 0.00% |

- **H1 handle: index by an id (a Table store covers)**: `ast.Ast.kind@ast.zig:530 | return self.recs.at(n.id).kind;` 5.58; `ast.Ast.parent@ast.zig:567 | return (__rig_rt_112: { var __rig_v_112 = as_node(self.recs.at(n.id).parent); _ = &__rig_v_112; break :__rig_r` 1.76; `ast.Ast.word_node@ast.zig:1029 | return (__rig_rt_203: { var __rig_v_203 = as_node(self.words.at(@as(i64, @intCast(@as(u32, self.recs.at(n.id).` 1.62
- **Z runtime and Zig std**: `hash.wyhash.Wyhash.read@wyhash.zig:134 | ` 0.74; `rig.table.Table(u32,536870912).push@table.zig:215 | ` 0.40; `hash.wyhash.Wyhash.final1@wyhash.zig:164 | ` 0.37
- **H2 handle: Table length read in check_id (lenHeld misses Table)**: `checker.Checker.checker_symbol@checker.zig:2627 | rig.rt(check_id((@as(i64, @intCast(@as(u32, s))) - @as(i64, @intCast(@as(u32, self.binder_syms)))) - 1, rig.le` 3.15; `compiler.Ids.binder_sym@compiler.zig:4534 | rig.rt(check_id(@as(i64, @intCast(@as(u32, s))), rig.lenOf(self.binder)));` 3.02; `compiler.Ids.node_id@compiler.zig:4513 | rig.rt(check_id(@as(i64, @intCast(@as(u32, file))) - 1, rig.lenOf(self.node_base)));` 1.71
- **H3 handle: inside a record (offset/slice; Table alone does not cover)**: `ast.Ast.word_node@ast.zig:1029 | return (__rig_rt_203: { var __rig_v_203 = as_node(self.words.at(@as(i64, @intCast(@as(u32, self.recs.at(n.id).` 3.31; `ast.Ast.word_list@ast.zig:1039 | return (__rig_rt_204: { var __rig_v_204 = as_list(self.words.at(@as(i64, @intCast(@as(u32, self.recs.at(n.id).` 1.08; `ast.Ast.nodes@ast.zig:574 | return rig.slice(self.list_nodes.items(), @as(i64, @intCast(@as(u32, r.start))), @as(i64, @intCast(@as(u32, r.` 0.85
- **H1 handle: index by an id (other List)**: `ast.Names.text@ast.zig:20217 | const end: i64 = @as(i64, @intCast(@as(u32, self.ends.atProven(i, .lower))));` 0.52; `ast.Ast.parent_list@ast.zig:1430 | const r = self.lists.at(self.words.at(i));` 0.44; `ast.Binding.declaration_of@ast.zig:18719 | return self.more_nodes.at((@as(i64, @intCast(@as(u32, self.symbol_extras.at(@as(i64, @intCast(@as(u32, extra))` 0.42
- **L List/slice index in checker**: `checker.Checker.synthetic_index@checker.zig:86475 | if (@as(i64, @intCast(@as(u32, n.node.id))) <= rig.rt(self.program.*.files.constSlot(@as(i64, @as(i64, @intCas` 0.99; `checker.Checker.node_kind@checker.zig:86503 | return self.synthetic_nodes.atProven(k, .lower).kind;` 0.43; `checker.Checker.node_kind@checker.zig:86505 | return rig.rt(self.program.*.files.constSlot(@as(i64, @as(i64, @intCast(@as(u32, n.file)))) -% 1).*.ast.kind(n` 0.41
- **C conversions/overflow elsewhere (checker)**: `checker.Checker.flow_memo_effect_sum@checker.zig:38205 | return (((((((((((@as(i64, @intCast(@as(u32, self.type_count))) + @as(i64, @intCast(@as(u32, self.signature_co` 0.89; `checker.Checker.union_front_state@checker.zig:5552 | const effects: i64 = ((((((((((@as(i64, @intCast(@as(u32, self.type_count))) + @as(i64, @intCast(@as(u32, self` 0.38; `checker.node_ref@checker.zig:97625 | return NodeRef{ .file = @as(u32, @intCast(@as(u64, @intCast(@as(i64, f + 1))))), .node = n };` 0.35
- **O other (ast index)**: `ast.Ast.parent_child@ast.zig:1420 | const w: u32 = self.words.at(i);` 0.49; `ast.Ast.parent_child@ast.zig:1422 | self.recs.slot(w).*.parent = p;` 0.45; `ast.Ast.parent_list@ast.zig:1430 | const r = self.lists.at(self.words.at(i));` 0.44
- **F front-end rule kinds: std**: `__rig_std_prelude.Set(checker.CacheKey).take@__rig_std_prelude.zig:288 | var key = self.t.take(k);` 0.23; `__rig_std_prelude.Map(checker.CacheKey,u32).put@__rig_std_prelude.zig:65 | if (self.t.put(rig.take(&__rig_alive_k, k), rig.take(&__rig_alive_v, v))) {` 0.18; `__rig_std_text.Interner.text@__rig_std_text.zig:680 | const end: i64 = @as(i64, @intCast(@as(u32, self.ends.atProven(i, .lower))));` 0.18

## Compiler (full c1; checks = 6.5% of cycles)

std Map/Set/Ordered (innermost frame in the tables): 1.75% of all weighted check branches (zig.integerOverflow 1.27, zig.integerOutOfBounds 0.36, zig.incorrectAlignment 0.07, zig.outOfBounds 0.05, zig.startGreaterThanEnd 0.01), ~0.13% of cycles; counted inside the rows below by their caller

| kind | share of all | share of live | ~% of cycles |
|---|---:|---:|---:|
| H1 handle: index by an id (a Table store covers) | 20.64% | 23.4% | 1.52% |
| (not run) b-built | 10.89% |  | ~0 |
| H2 handle: Table length read in check_id (lenHeld misses Table) | 10.35% | 11.7% | 0.76% |
| H1 handle: index by an id (other List) | 8.79% | 10.0% | 0.65% |
| H3 handle: inside a record (offset/slice; Table alone does not cover) | 8.32% | 9.4% | 0.61% |
| L List/slice index in checker | 7.06% | 8.0% | 0.52% |
| Z runtime and Zig std | 6.56% | 7.4% | 0.48% |
| C conversions/overflow elsewhere (checker) | 6.04% | 6.8% | 0.44% |
| O other (ast index) | 4.50% | 5.1% | 0.33% |
| F front-end rule kinds: a | 2.83% | 3.2% | 0.21% |
| F front-end rule kinds: std | 2.10% | 2.4% | 0.15% |
| F front-end rule kinds: c2r | 1.37% | 1.6% | 0.10% |
| F front-end rule kinds: e | 1.33% | 1.5% | 0.10% |
| F front-end rule kinds: a+ | 1.26% | 1.4% | 0.09% |
| C conversions/overflow elsewhere (ast) | 0.97% | 1.1% | 0.07% |
| F front-end rule kinds: c2n | 0.83% | 0.9% | 0.06% |
| (not run) cold | 0.81% |  | ~0 |
| F front-end rule kinds: hash | 0.80% | 0.9% | 0.06% |
| F front-end rule kinds: b+ | 0.78% | 0.9% | 0.06% |
| F front-end rule kinds: c2p | 0.70% | 0.8% | 0.05% |
| R conversions/overflow in relation code | 0.60% | 0.7% | 0.04% |
| O other (ast slice) | 0.52% | 0.6% | 0.04% |
| O other (lexer index) | 0.42% | 0.5% | 0.03% |
| F front-end rule kinds: ctr | 0.35% | 0.4% | 0.03% |
| C conversions/overflow elsewhere (core) | 0.29% | 0.3% | 0.02% |
| O other (core index) | 0.19% | 0.2% | 0.01% |
| C conversions/overflow elsewhere (parser) | 0.12% | 0.1% | 0.01% |
| O other (parser index) | 0.11% | 0.1% | 0.01% |
| L List/slice index in binder | 0.06% | 0.1% | 0.00% |
| O other (parser slice) | 0.05% | 0.1% | 0.00% |
| O other (jsnum slice) | 0.04% | 0.1% | 0.00% |
| C conversions/overflow elsewhere (c) | 0.03% | 0.0% | 0.00% |
| C conversions/overflow elsewhere (collections) | 0.03% | 0.0% | 0.00% |
| O other (collections index) | 0.03% | 0.0% | 0.00% |
| O other (checker len) | 0.03% | 0.0% | 0.00% |
| O other (tspath slice) | 0.02% | 0.0% | 0.00% |
| C conversions/overflow elsewhere (tspath) | 0.02% | 0.0% | 0.00% |
| C conversions/overflow elsewhere (compiler) | 0.02% | 0.0% | 0.00% |
| C conversions/overflow elsewhere (jsnum) | 0.01% | 0.0% | 0.00% |
| O other (jsnum index) | 0.01% | 0.0% | 0.00% |
| C conversions/overflow elsewhere (printer) | 0.01% | 0.0% | 0.00% |
| C conversions/overflow elsewhere (binder) | 0.01% | 0.0% | 0.00% |
| C conversions/overflow elsewhere (lexer) | 0.01% | 0.0% | 0.00% |
| L List/slice index in compiler | 0.00% | 0.0% | 0.00% |
| O other (tspath index) | 0.00% | 0.0% | 0.00% |
| C conversions/overflow elsewhere (execute) | 0.00% | 0.0% | 0.00% |
| O other (diagnosticwriter index) | 0.00% | 0.0% | 0.00% |
| O other (printer zbounds) | 0.00% | 0.0% | 0.00% |
| O other (parser zbounds) | 0.00% | 0.0% | 0.00% |
| L List/slice index in declarations | 0.00% | 0.0% | 0.00% |
| O other (tsoptions index) | 0.00% | 0.0% | 0.00% |
| O other (declarations zbounds) | 0.00% | 0.0% | 0.00% |
| O other (execute index) | 0.00% | 0.0% | 0.00% |
| C conversions/overflow elsewhere (tsoptions) | 0.00% | 0.0% | 0.00% |

- **H1 handle: index by an id (a Table store covers)**: `ast.Ast.kind@ast.zig:530 | return self.recs.at(n.id).kind;` 6.11; `ast.Ast.parent@ast.zig:567 | return (__rig_rt_112: { var __rig_v_112 = as_node(self.recs.at(n.id).parent); _ = &__rig_v_112; break :__rig_r` 2.12; `ast.Ast.word_node@ast.zig:1029 | return (__rig_rt_203: { var __rig_v_203 = as_node(self.words.at(@as(i64, @intCast(@as(u32, self.recs.at(n.id).` 1.54
- **H2 handle: Table length read in check_id (lenHeld misses Table)**: `checker.Checker.checker_symbol@checker.zig:2627 | rig.rt(check_id((@as(i64, @intCast(@as(u32, s))) - @as(i64, @intCast(@as(u32, self.binder_syms)))) - 1, rig.le` 3.00; `compiler.Ids.binder_sym@compiler.zig:4534 | rig.rt(check_id(@as(i64, @intCast(@as(u32, s))), rig.lenOf(self.binder)));` 2.99; `compiler.Ids.node_id@compiler.zig:4513 | rig.rt(check_id(@as(i64, @intCast(@as(u32, file))) - 1, rig.lenOf(self.node_base)));` 1.94
- **H1 handle: index by an id (other List)**: `ast.Binding.declaration_of@ast.zig:18719 | return self.more_nodes.at((@as(i64, @intCast(@as(u32, self.symbol_extras.at(@as(i64, @intCast(@as(u32, extra))` 0.46; `checker.Checker.data_declaration@checker.zig:2895 | return self.more_declarations.constSlot(@as(i64, @intCast(@as(u32, d.more))) - 1).*.at(j);` 0.41; `ast.Names.text@ast.zig:20217 | const end: i64 = @as(i64, @intCast(@as(u32, self.ends.atProven(i, .lower))));` 0.31
- **H3 handle: inside a record (offset/slice; Table alone does not cover)**: `ast.Ast.word_node@ast.zig:1029 | return (__rig_rt_203: { var __rig_v_203 = as_node(self.words.at(@as(i64, @intCast(@as(u32, self.recs.at(n.id).` 3.22; `ast.Ast.word_list@ast.zig:1039 | return (__rig_rt_204: { var __rig_v_204 = as_list(self.words.at(@as(i64, @intCast(@as(u32, self.recs.at(n.id).` 1.14; `ast.Ast.nodes@ast.zig:574 | return rig.slice(self.list_nodes.items(), @as(i64, @intCast(@as(u32, r.start))), @as(i64, @intCast(@as(u32, r.` 0.88
- **L List/slice index in checker**: `checker.Checker.synthetic_index@checker.zig:86475 | if (@as(i64, @intCast(@as(u32, n.node.id))) <= rig.rt(self.program.*.files.constSlot(@as(i64, @as(i64, @intCas` 0.90; `checker.Checker.data_declaration@checker.zig:2895 | return self.more_declarations.constSlot(@as(i64, @intCast(@as(u32, d.more))) - 1).*.at(j);` 0.41; `checker.Checker.synthetic_index@checker.zig:86472 | if ((rig.lenOf(self.synthetic_nodes) == 0) or (n.file == 0)) {` 0.39
- **Z runtime and Zig std**: `rig.table.Table(u32,536870912).push@table.zig:215 | ` 0.40; `checker.Layout.home@checker.zig:88341 | return @as(i64, @intCast(@as(u64, @as(u64, @as(u64, @as(u64, @intCast(@as(u32, name)))) *% 0x9E3779B97F4A7C15)` 0.31; `ast.BigTable.home@ast.zig:18141 | return @as(i64, @intCast(@as(u64, @as(u64, @as(u64, @as(u64, @intCast(@as(u32, name)))) *% 0x9E3779B97F4A7C15)` 0.30
- **C conversions/overflow elsewhere (checker)**: `checker.Checker.flow_memo_effect_sum@checker.zig:38205 | return (((((((((((@as(i64, @intCast(@as(u32, self.type_count))) + @as(i64, @intCast(@as(u32, self.signature_co` 1.32; `checker.node_ref@checker.zig:97625 | return NodeRef{ .file = @as(u32, @intCast(@as(u64, @intCast(@as(i64, f + 1))))), .node = n };` 0.44; `checker.Checker.flow_memo_store@checker.zig:0 | ` 0.30
- **O other (ast index)**: `ast.Ast.text@ast.zig:0 | ` 0.94; `ast.Ast.parent_child@ast.zig:1420 | const w: u32 = self.words.at(i);` 0.31; `ast.BigTable.place_of@ast.zig:18166 | const s: u32 = self.slots.at(i);` 0.29
- **F front-end rule kinds: a**: `ast.Ast.new_node@ast.zig:668 | return Node{ .id = @as(u32, @intCast(@as(u64, @intCast(@as(i64, rig.lenOf(self.recs) - 1))))) };` 0.50; `ast.Ast.add_list@ast.zig:980 | self.lists.push(ListRec{ .pos = @as(i32, @intCast(@as(i64, __rig_local_pos_187))), .end = @as(i32, @intCast(@a` 0.34; `ast.Ast.new_node@ast.zig:666 | self.recs.push(NodeRec{ .kind = __rig_local_kind_113, .keyword = .Unknown, .parent = 0, .data = @as(u32, @intC` 0.26

## Compiler-Unions (full c1; checks = 5.5% of cycles)

std Map/Set/Ordered (innermost frame in the tables): 3.00% of all weighted check branches (zig.integerOverflow 2.13, zig.integerOutOfBounds 0.59, zig.incorrectAlignment 0.15, zig.outOfBounds 0.11, zig.startGreaterThanEnd 0.01), ~0.18% of cycles; counted inside the rows below by their caller

| kind | share of all | share of live | ~% of cycles |
|---|---:|---:|---:|
| H1 handle: index by an id (a Table store covers) | 17.53% | 19.3% | 1.06% |
| H2 handle: Table length read in check_id (lenHeld misses Table) | 12.97% | 14.3% | 0.78% |
| H1 handle: index by an id (other List) | 10.94% | 12.0% | 0.66% |
| (not run) b-built | 8.50% |  | ~0 |
| Z runtime and Zig std | 7.64% | 8.4% | 0.46% |
| H3 handle: inside a record (offset/slice; Table alone does not cover) | 7.59% | 8.3% | 0.46% |
| L List/slice index in checker | 7.28% | 8.0% | 0.44% |
| C conversions/overflow elsewhere (checker) | 5.53% | 6.1% | 0.33% |
| O other (ast index) | 5.18% | 5.7% | 0.31% |
| F front-end rule kinds: std | 4.04% | 4.4% | 0.24% |
| F front-end rule kinds: a | 2.16% | 2.4% | 0.13% |
| R conversions/overflow in relation code | 1.95% | 2.1% | 0.12% |
| F front-end rule kinds: e | 1.13% | 1.2% | 0.07% |
| F front-end rule kinds: a+ | 0.97% | 1.1% | 0.06% |
| F front-end rule kinds: hash | 0.94% | 1.0% | 0.06% |
| C conversions/overflow elsewhere (ast) | 0.93% | 1.0% | 0.06% |
| F front-end rule kinds: c2r | 0.79% | 0.9% | 0.05% |
| O other (ast slice) | 0.75% | 0.8% | 0.05% |
| (not run) cold | 0.55% |  | ~0 |
| F front-end rule kinds: c2n | 0.54% | 0.6% | 0.03% |
| F front-end rule kinds: ctr | 0.46% | 0.5% | 0.03% |
| O other (lexer index) | 0.33% | 0.4% | 0.02% |
| F front-end rule kinds: b+ | 0.28% | 0.3% | 0.02% |
| C conversions/overflow elsewhere (core) | 0.18% | 0.2% | 0.01% |
| F front-end rule kinds: data | 0.13% | 0.1% | 0.01% |
| O other (parser index) | 0.13% | 0.1% | 0.01% |
| O other (core index) | 0.12% | 0.1% | 0.01% |
| C conversions/overflow elsewhere (parser) | 0.09% | 0.1% | 0.01% |
| C conversions/overflow elsewhere (lexer) | 0.05% | 0.1% | 0.00% |
| L List/slice index in binder | 0.04% | 0.0% | 0.00% |
| O other (checker len) | 0.04% | 0.0% | 0.00% |
| C conversions/overflow elsewhere (printer) | 0.03% | 0.0% | 0.00% |
| O other (parser slice) | 0.03% | 0.0% | 0.00% |
| C conversions/overflow elsewhere (collections) | 0.02% | 0.0% | 0.00% |
| O other (lexer slice) | 0.02% | 0.0% | 0.00% |
| O other (diagnostics slice) | 0.02% | 0.0% | 0.00% |
| O other (tspath slice) | 0.02% | 0.0% | 0.00% |
| O other (jsnum slice) | 0.01% | 0.0% | 0.00% |
| C conversions/overflow elsewhere (diagnostics) | 0.01% | 0.0% | 0.00% |
| O other (diagnostics index) | 0.01% | 0.0% | 0.00% |
| O other (collections index) | 0.01% | 0.0% | 0.00% |
| F front-end rule kinds: c2p | 0.01% | 0.0% | 0.00% |
| C conversions/overflow elsewhere (tspath) | 0.01% | 0.0% | 0.00% |
| O other (tspath index) | 0.01% | 0.0% | 0.00% |
| C conversions/overflow elsewhere (jsnum) | 0.01% | 0.0% | 0.00% |
| O other (jsnum index) | 0.01% | 0.0% | 0.00% |
| L List/slice index in compiler | 0.00% | 0.0% | 0.00% |
| O other (parser zbounds) | 0.00% | 0.0% | 0.00% |
| O other (vfs index) | 0.00% | 0.0% | 0.00% |
| C conversions/overflow elsewhere (c) | 0.00% | 0.0% | 0.00% |
| C conversions/overflow elsewhere (vfs) | 0.00% | 0.0% | 0.00% |
| C conversions/overflow elsewhere (compiler) | 0.00% | 0.0% | 0.00% |
| O other (vfs slice) | 0.00% | 0.0% | 0.00% |

- **H1 handle: index by an id (a Table store covers)**: `ast.Ast.kind@ast.zig:530 | return self.recs.at(n.id).kind;` 5.16; `ast.Ast.parent@ast.zig:567 | return (__rig_rt_112: { var __rig_v_112 = as_node(self.recs.at(n.id).parent); _ = &__rig_v_112; break :__rig_r` 1.87; `ast.Ast.word_node@ast.zig:1029 | return (__rig_rt_203: { var __rig_v_203 = as_node(self.words.at(@as(i64, @intCast(@as(u32, self.recs.at(n.id).` 1.45
- **H2 handle: Table length read in check_id (lenHeld misses Table)**: `checker.Checker.checker_symbol@checker.zig:2627 | rig.rt(check_id((@as(i64, @intCast(@as(u32, s))) - @as(i64, @intCast(@as(u32, self.binder_syms)))) - 1, rig.le` 4.28; `compiler.Ids.binder_sym@compiler.zig:4534 | rig.rt(check_id(@as(i64, @intCast(@as(u32, s))), rig.lenOf(self.binder)));` 3.90; `compiler.Ids.node_id@compiler.zig:4513 | rig.rt(check_id(@as(i64, @intCast(@as(u32, file))) - 1, rig.lenOf(self.node_base)));` 1.79
- **H1 handle: index by an id (other List)**: `ast.Names.text@ast.zig:20217 | const end: i64 = @as(i64, @intCast(@as(u32, self.ends.atProven(i, .lower))));` 0.69; `checker.Layout.get@checker.zig:88356 | const s: u32 = self.slots.at(i);` 0.69; `checker.Layout.get@checker.zig:88360 | if (self.names.at(@as(i64, @intCast(@as(u32, s))) - 1) == name) {` 0.69
- **Z runtime and Zig std**: `checker.Layout.home@checker.zig:88341 | return @as(i64, @intCast(@as(u64, @as(u64, @as(u64, @as(u64, @intCast(@as(u32, name)))) *% 0x9E3779B97F4A7C15)` 0.72; `ast.BigTable.home@ast.zig:18141 | return @as(i64, @intCast(@as(u64, @as(u64, @as(u64, @as(u64, @intCast(@as(u32, name)))) *% 0x9E3779B97F4A7C15)` 0.69; `rig.table.Table(u32,536870912).push@table.zig:215 | ` 0.41
- **H3 handle: inside a record (offset/slice; Table alone does not cover)**: `ast.Ast.word_node@ast.zig:1029 | return (__rig_rt_203: { var __rig_v_203 = as_node(self.words.at(@as(i64, @intCast(@as(u32, self.recs.at(n.id).` 2.94; `ast.Ast.word_list@ast.zig:1039 | return (__rig_rt_204: { var __rig_v_204 = as_list(self.words.at(@as(i64, @intCast(@as(u32, self.recs.at(n.id).` 0.91; `ast.Ast.nodes@ast.zig:574 | return rig.slice(self.list_nodes.items(), @as(i64, @intCast(@as(u32, r.start))), @as(i64, @intCast(@as(u32, r.` 0.72
- **L List/slice index in checker**: `checker.Checker.synthetic_index@checker.zig:86475 | if (@as(i64, @intCast(@as(u32, n.node.id))) <= rig.rt(self.program.*.files.constSlot(@as(i64, @as(i64, @intCas` 0.77; `checker.Checker.data_declaration@checker.zig:2895 | return self.more_declarations.constSlot(@as(i64, @intCast(@as(u32, d.more))) - 1).*.at(j);` 0.44; `checker.Checker.node_kind@checker.zig:86503 | return self.synthetic_nodes.atProven(k, .lower).kind;` 0.42
- **C conversions/overflow elsewhere (checker)**: `checker.Checker.flow_memo_effect_sum@checker.zig:38205 | return (((((((((((@as(i64, @intCast(@as(u32, self.type_count))) + @as(i64, @intCast(@as(u32, self.signature_co` 0.93; `checker.Checker.union_front_state@checker.zig:5552 | const effects: i64 = ((((((((((@as(i64, @intCast(@as(u32, self.type_count))) + @as(i64, @intCast(@as(u32, self` 0.23; `checker.Checker.flow_memo_store@checker.zig:0 | ` 0.21
- **O other (ast index)**: `ast.BigTable.place_of@ast.zig:18166 | const s: u32 = self.slots.at(i);` 0.68; `ast.Binding.table_get_unmasked@ast.zig:18392 | return rig.rt(self.big_tables.constSlot(@as(i64, @intCast(@as(u32, h.start)))).*.get(name));` 0.67; `ast.BigTable.get@ast.zig:18187 | return self.entries.at(k).symbol;` 0.67
- **F front-end rule kinds: std**: `__rig_std_prelude.Set(checker.CacheKey).take@__rig_std_prelude.zig:288 | var key = self.t.take(k);` 0.74; `__rig_std_prelude.Map(checker.CacheKey,u32).put@__rig_std_prelude.zig:65 | if (self.t.put(rig.take(&__rig_alive_k, k), rig.take(&__rig_alive_v, v))) {` 0.39; `__rig_std_text.Interner.text@__rig_std_text.zig:680 | const end: i64 = @as(i64, @intCast(@as(u32, self.ends.atProven(i, .lower))));` 0.35

