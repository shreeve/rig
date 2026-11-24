## webpack (full c1; checks = 5.8% of cycles)

std Map/Set/Ordered (innermost frame in the tables): 3.41% of all weighted check branches (zig.integerOverflow 2.30, zig.integerOutOfBounds 0.73, zig.incorrectAlignment 0.27, zig.outOfBounds 0.07, zig.startGreaterThanEnd 0.03, indexPanic 0.00, lenPanic 0.00, rig.table.fullPanic 0.00, zig.integerPartOutOfBounds 0.00), ~0.23% of cycles; counted inside the rows below by their caller

| kind | share of all | share of live | ~% of cycles |
|---|---:|---:|---:|
| H1 handle: index by an id (a Table store covers) | 19.17% | 22.0% | 1.28% |
| (not run) b-built | 12.74% |  | ~0 |
| H3 handle: inside a record (offset/slice; Table alone does not cover) | 11.12% | 12.7% | 0.74% |
| Z runtime and Zig std | 8.67% | 9.9% | 0.58% |
| H1 handle: index by an id (other List) | 8.19% | 9.4% | 0.55% |
| L List/slice index in checker | 7.78% | 8.9% | 0.52% |
| O other (ast index) | 6.53% | 7.5% | 0.43% |
| F front-end rule kinds: std | 4.40% | 5.0% | 0.29% |
| C conversions/overflow elsewhere (checker) | 3.69% | 4.2% | 0.25% |
| F front-end rule kinds: a | 3.24% | 3.7% | 0.22% |
| F front-end rule kinds: b+ | 2.07% | 2.4% | 0.14% |
| F front-end rule kinds: e | 1.71% | 2.0% | 0.11% |
| R conversions/overflow in relation code | 1.64% | 1.9% | 0.11% |
| F front-end rule kinds: a+ | 1.51% | 1.7% | 0.10% |
| F front-end rule kinds: hash | 1.47% | 1.7% | 0.10% |
| C conversions/overflow elsewhere (ast) | 1.31% | 1.5% | 0.09% |
| F front-end rule kinds: c2r | 1.18% | 1.4% | 0.08% |
| F front-end rule kinds: ctr | 0.36% | 0.4% | 0.02% |
| C conversions/overflow elsewhere (parser) | 0.31% | 0.4% | 0.02% |
| F front-end rule kinds: c2p | 0.30% | 0.3% | 0.02% |
| O other (ast slice) | 0.30% | 0.3% | 0.02% |
| O other (tspath slice) | 0.21% | 0.2% | 0.01% |
| F front-end rule kinds: c2n | 0.21% | 0.2% | 0.01% |
| O other (lexer index) | 0.21% | 0.2% | 0.01% |
| C conversions/overflow elsewhere (core) | 0.20% | 0.2% | 0.01% |
| C conversions/overflow elsewhere (tspath) | 0.19% | 0.2% | 0.01% |
| O other (core index) | 0.14% | 0.2% | 0.01% |
| F front-end rule kinds: data | 0.14% | 0.2% | 0.01% |
| O other (parser index) | 0.13% | 0.1% | 0.01% |
| C conversions/overflow elsewhere (lexer) | 0.10% | 0.1% | 0.01% |
| O other (parser slice) | 0.09% | 0.1% | 0.01% |
| (not run) cold | 0.07% |  | ~0 |
| C conversions/overflow elsewhere (compiler) | 0.07% | 0.1% | 0.00% |
| O other (jsnum slice) | 0.07% | 0.1% | 0.00% |
| O other (lexer slice) | 0.06% | 0.1% | 0.00% |
| O other (tspath index) | 0.04% | 0.0% | 0.00% |
| L List/slice index in compiler | 0.03% | 0.0% | 0.00% |
| C conversions/overflow elsewhere (printer) | 0.03% | 0.0% | 0.00% |
| C conversions/overflow elsewhere (jsnum) | 0.03% | 0.0% | 0.00% |
| C conversions/overflow elsewhere (rig) | 0.02% | 0.0% | 0.00% |
| O other (stringutil index) | 0.02% | 0.0% | 0.00% |
| O other (module index) | 0.01% | 0.0% | 0.00% |
| C conversions/overflow elsewhere (collections) | 0.01% | 0.0% | 0.00% |
| O other (core slice) | 0.01% | 0.0% | 0.00% |
| L List/slice index in binder | 0.01% | 0.0% | 0.00% |
| C conversions/overflow elsewhere (binder) | 0.01% | 0.0% | 0.00% |
| O other (jsnum index) | 0.01% | 0.0% | 0.00% |
| O other (vfsmatch index) | 0.01% | 0.0% | 0.00% |
| O other (collections index) | 0.01% | 0.0% | 0.00% |
| O other (diagnostics slice) | 0.00% | 0.0% | 0.00% |
| C conversions/overflow elsewhere (vfs) | 0.00% | 0.0% | 0.00% |
| O other (packagejson index) | 0.00% | 0.0% | 0.00% |
| C conversions/overflow elsewhere (diagnostics) | 0.00% | 0.0% | 0.00% |
| O other (diagnostics index) | 0.00% | 0.0% | 0.00% |
| C conversions/overflow elsewhere (module) | 0.00% | 0.0% | 0.00% |
| O other (module slice) | 0.00% | 0.0% | 0.00% |
| C conversions/overflow elsewhere (packagejson) | 0.00% | 0.0% | 0.00% |
| O other (diagnosticwriter index) | 0.00% | 0.0% | 0.00% |
| C conversions/overflow elsewhere (process) | 0.00% | 0.0% | 0.00% |
| O other (printer index) | 0.00% | 0.0% | 0.00% |
| L List/slice index in declarations | 0.00% | 0.0% | 0.00% |
| C conversions/overflow elsewhere (diagnosticwriter) | 0.00% | 0.0% | 0.00% |
| C conversions/overflow elsewhere (vfsmatch) | 0.00% | 0.0% | 0.00% |
| C conversions/overflow elsewhere (execute) | 0.00% | 0.0% | 0.00% |
| O other (execute index) | 0.00% | 0.0% | 0.00% |
| C conversions/overflow elsewhere (tsoptions) | 0.00% | 0.0% | 0.00% |

- **H1 handle: index by an id (a Table store covers)**: `ast.Ast.kind@ast.zig:446 | return self.recs.at(n.id).kind;` 5.07; `ast.Ast.word_node@ast.zig:922 | return (__rig_rt_178: { var __rig_v_178 = as_node(self.words.at(@as(i64, @intCast(@as(u32, self.recs.at(n.id).` 1.78; `ast.Ast.nodes@ast.zig:489 | const r = self.lists.at(l.id);` 1.64
- **H3 handle: inside a record (offset/slice; Table alone does not cover)**: `ast.Ast.word_node@ast.zig:922 | return (__rig_rt_178: { var __rig_v_178 = as_node(self.words.at(@as(i64, @intCast(@as(u32, self.recs.at(n.id).` 3.88; `ast.Ast.word_list@ast.zig:932 | return (__rig_rt_179: { var __rig_v_179 = as_list(self.words.at(@as(i64, @intCast(@as(u32, self.recs.at(n.id).` 1.66; `ast.Ast.nodes@ast.zig:490 | return rig.slice(self.list_nodes.items(), @as(i64, @intCast(@as(u32, r.start))), @as(i64, @intCast(@as(u32, r.` 1.36
- **Z runtime and Zig std**: `rig.table.Table(u32,536870912).push@table.zig:215 | ` 0.58; `checker.Checker.new_type_list@checker.zig:80226 | const start: u32 = @as(u32, @intCast(@as(u64, @intCast(@as(i64, rig.lenOf(self.store.type_lists))))));` 0.37; `rig.table.Table(u32,134217728).push@table.zig:215 | ` 0.34
- **H1 handle: index by an id (other List)**: `ast.Binding.declaration_of@ast.zig:18146 | return self.more_nodes.at((@as(i64, @intCast(@as(u32, self.symbol_extras.at(@as(i64, @intCast(@as(u32, extra))` 1.04; `ast.Ast.parent_list@ast.zig:1256 | const r = self.lists.at(self.words.at(i));` 0.92; `checker.Checker.data_declaration@checker.zig:2895 | return self.more_declarations.constSlot(@as(i64, @intCast(@as(u32, d.more))) - 1).*.at(j);` 0.53
- **L List/slice index in checker**: `checker.Checker.data_declaration@checker.zig:2895 | return self.more_declarations.constSlot(@as(i64, @intCast(@as(u32, d.more))) - 1).*.at(j);` 0.53; `checker.Checker.symbol_declaration_count@checker.zig:2819 | return rig.rt(self.program.*.bindings.constSlot(@as(i64, @intCast(@as(u32, b.file())))).*.declaration_count_of` 0.51; `checker.Checker.synthetic_index@checker.zig:86450 | if (@as(i64, @intCast(@as(u32, n.node.id))) <= rig.rt(self.program.*.files.constSlot(@as(i64, @as(i64, @intCas` 0.51
- **O other (ast index)**: `ast.Ast.parent_child@ast.zig:1246 | const w: u32 = self.words.at(i);` 1.33; `ast.Ast.parent_child@ast.zig:1248 | self.recs.slot(w).*.parent = p;` 1.13; `ast.Ast.parent_list@ast.zig:1263 | self.recs.slot(self.list_nodes.at(k).id).*.parent = p;` 0.92
- **F front-end rule kinds: std**: `__rig_std_prelude.Map(u32,u32).put@__rig_std_prelude.zig:65 | if (self.t.put(rig.take(&__rig_alive_k, k), rig.take(&__rig_alive_v, v))) {` 0.33; `__rig_std_prelude.Set(u32).add@__rig_std_prelude.zig:278 | const added: bool = self.t.add(rig.take(&__rig_alive_k, k));` 0.29; `__rig_std_text.Interner.text@__rig_std_text.zig:682 | return rig.slice(self.bytes.bytes(), start, end);` 0.29
- **C conversions/overflow elsewhere (checker)**: `checker.Checker.union_front_state@checker.zig:5566 | const effects: i64 = ((((((((((@as(i64, @intCast(@as(u32, self.type_count))) + @as(i64, @intCast(@as(u32, self` 0.64; `checker.node_ref@checker.zig:97409 | return NodeRef{ .file = @as(u32, @intCast(@as(u64, @intCast(@as(i64, f + 1))))), .node = n };` 0.30; `checker.Checker.flow_memo_effect_sum@checker.zig:38233 | return (((((((((((@as(i64, @intCast(@as(u32, self.type_count))) + @as(i64, @intCast(@as(u32, self.signature_co` 0.25
- **F front-end rule kinds: a**: `ast.Ast.new_node@ast.zig:584 | return Node{ .id = @as(u32, @intCast(@as(u64, @intCast(@as(i64, rig.lenOf(self.recs) - 1))))) };` 0.57; `checker.Checker.new_type_list@checker.zig:80226 | const start: u32 = @as(u32, @intCast(@as(u64, @intCast(@as(i64, rig.lenOf(self.store.type_lists))))));` 0.37; `ast.Ast.new_node@ast.zig:582 | self.recs.push(NodeRec{ .kind = __rig_local_kind_93, .keyword = .Unknown, .parent = 0, .data = @as(u32, @intCa` 0.31

## typeorm (full c1; checks = 5.4% of cycles)

std Map/Set/Ordered (innermost frame in the tables): 3.54% of all weighted check branches (zig.integerOverflow 2.32, zig.integerOutOfBounds 0.77, zig.incorrectAlignment 0.30, zig.outOfBounds 0.12, zig.startGreaterThanEnd 0.03, indexPanic 0.00, lenPanic 0.00, rig.table.fullPanic 0.00, zig.integerPartOutOfBounds 0.00), ~0.22% of cycles; counted inside the rows below by their caller

| kind | share of all | share of live | ~% of cycles |
|---|---:|---:|---:|
| H1 handle: index by an id (a Table store covers) | 17.83% | 20.4% | 1.10% |
| (not run) b-built | 12.38% |  | ~0 |
| Z runtime and Zig std | 10.84% | 12.4% | 0.67% |
| H3 handle: inside a record (offset/slice; Table alone does not cover) | 10.51% | 12.0% | 0.65% |
| H1 handle: index by an id (other List) | 8.57% | 9.8% | 0.53% |
| L List/slice index in checker | 7.57% | 8.7% | 0.47% |
| O other (ast index) | 7.10% | 8.1% | 0.44% |
| F front-end rule kinds: std | 3.88% | 4.4% | 0.24% |
| C conversions/overflow elsewhere (checker) | 3.84% | 4.4% | 0.24% |
| F front-end rule kinds: a | 2.86% | 3.3% | 0.18% |
| F front-end rule kinds: b+ | 2.44% | 2.8% | 0.15% |
| R conversions/overflow in relation code | 1.66% | 1.9% | 0.10% |
| F front-end rule kinds: e | 1.41% | 1.6% | 0.09% |
| F front-end rule kinds: hash | 1.41% | 1.6% | 0.09% |
| C conversions/overflow elsewhere (ast) | 1.33% | 1.5% | 0.08% |
| F front-end rule kinds: a+ | 1.25% | 1.4% | 0.08% |
| F front-end rule kinds: c2r | 1.10% | 1.3% | 0.07% |
| O other (tspath slice) | 0.77% | 0.9% | 0.05% |
| C conversions/overflow elsewhere (tspath) | 0.70% | 0.8% | 0.04% |
| F front-end rule kinds: ctr | 0.36% | 0.4% | 0.02% |
| F front-end rule kinds: c2n | 0.21% | 0.2% | 0.01% |
| O other (ast slice) | 0.21% | 0.2% | 0.01% |
| F front-end rule kinds: c2p | 0.19% | 0.2% | 0.01% |
| O other (tspath index) | 0.19% | 0.2% | 0.01% |
| O other (lexer index) | 0.18% | 0.2% | 0.01% |
| C conversions/overflow elsewhere (parser) | 0.15% | 0.2% | 0.01% |
| C conversions/overflow elsewhere (compiler) | 0.13% | 0.1% | 0.01% |
| O other (parser index) | 0.10% | 0.1% | 0.01% |
| O other (vfsmatch index) | 0.10% | 0.1% | 0.01% |
| (not run) cold | 0.08% |  | ~0 |
| O other (jsnum slice) | 0.08% | 0.1% | 0.00% |
| L List/slice index in compiler | 0.07% | 0.1% | 0.00% |
| F front-end rule kinds: data | 0.07% | 0.1% | 0.00% |
| C conversions/overflow elsewhere (lexer) | 0.07% | 0.1% | 0.00% |
| O other (parser slice) | 0.06% | 0.1% | 0.00% |
| O other (module index) | 0.05% | 0.1% | 0.00% |
| O other (lexer slice) | 0.04% | 0.0% | 0.00% |
| C conversions/overflow elsewhere (rig) | 0.03% | 0.0% | 0.00% |
| C conversions/overflow elsewhere (jsnum) | 0.03% | 0.0% | 0.00% |
| O other (core slice) | 0.03% | 0.0% | 0.00% |
| C conversions/overflow elsewhere (collections) | 0.02% | 0.0% | 0.00% |
| C conversions/overflow elsewhere (vfs) | 0.02% | 0.0% | 0.00% |
| L List/slice index in binder | 0.01% | 0.0% | 0.00% |
| O other (packagejson index) | 0.01% | 0.0% | 0.00% |
| C conversions/overflow elsewhere (packagejson) | 0.01% | 0.0% | 0.00% |
| C conversions/overflow elsewhere (printer) | 0.01% | 0.0% | 0.00% |
| C conversions/overflow elsewhere (module) | 0.01% | 0.0% | 0.00% |
| O other (jsnum index) | 0.01% | 0.0% | 0.00% |
| O other (collections index) | 0.01% | 0.0% | 0.00% |
| O other (module slice) | 0.01% | 0.0% | 0.00% |
| O other (diagnostics index) | 0.01% | 0.0% | 0.00% |
| O other (diagnostics slice) | 0.01% | 0.0% | 0.00% |
| C conversions/overflow elsewhere (core) | 0.01% | 0.0% | 0.00% |
| L List/slice index in declarations | 0.00% | 0.0% | 0.00% |
| C conversions/overflow elsewhere (vfsmatch) | 0.00% | 0.0% | 0.00% |
| C conversions/overflow elsewhere (binder) | 0.00% | 0.0% | 0.00% |
| C conversions/overflow elsewhere (diagnostics) | 0.00% | 0.0% | 0.00% |
| O other (core index) | 0.00% | 0.0% | 0.00% |
| C conversions/overflow elsewhere (__rig_main) | 0.00% | 0.0% | 0.00% |
| C conversions/overflow elsewhere (stringutil) | 0.00% | 0.0% | 0.00% |
| O other (stringutil index) | 0.00% | 0.0% | 0.00% |
| O other (printer index) | 0.00% | 0.0% | 0.00% |
| O other (vfsmatch slice) | 0.00% | 0.0% | 0.00% |
| O other (__rig_main index) | 0.00% | 0.0% | 0.00% |
| C conversions/overflow elsewhere (tsoptions) | 0.00% | 0.0% | 0.00% |
| O other (tsoptions index) | 0.00% | 0.0% | 0.00% |

- **H1 handle: index by an id (a Table store covers)**: `ast.Ast.kind@ast.zig:446 | return self.recs.at(n.id).kind;` 4.74; `ast.Ast.word_node@ast.zig:922 | return (__rig_rt_178: { var __rig_v_178 = as_node(self.words.at(@as(i64, @intCast(@as(u32, self.recs.at(n.id).` 1.74; `ast.Ast.nodes@ast.zig:489 | const r = self.lists.at(l.id);` 1.41
- **Z runtime and Zig std**: `hash.wyhash.Wyhash.read@wyhash.zig:134 | ` 0.57; `rig.table.Table(u32,536870912).push@table.zig:215 | ` 0.51; `rig.std.text.search@text.zig:121 | ` 0.50
- **H3 handle: inside a record (offset/slice; Table alone does not cover)**: `ast.Ast.word_node@ast.zig:922 | return (__rig_rt_178: { var __rig_v_178 = as_node(self.words.at(@as(i64, @intCast(@as(u32, self.recs.at(n.id).` 3.67; `ast.Ast.word_list@ast.zig:932 | return (__rig_rt_179: { var __rig_v_179 = as_list(self.words.at(@as(i64, @intCast(@as(u32, self.recs.at(n.id).` 1.38; `ast.Ast.parent_list@ast.zig:1263 | self.recs.slot(self.list_nodes.at(k).id).*.parent = p;` 1.12
- **H1 handle: index by an id (other List)**: `ast.Ast.parent_list@ast.zig:1256 | const r = self.lists.at(self.words.at(i));` 1.11; `ast.Binding.declaration_of@ast.zig:18146 | return self.more_nodes.at((@as(i64, @intCast(@as(u32, self.symbol_extras.at(@as(i64, @intCast(@as(u32, extra))` 1.07; `checker.Checker.data_declaration@checker.zig:2895 | return self.more_declarations.constSlot(@as(i64, @intCast(@as(u32, d.more))) - 1).*.at(j);` 0.55
- **L List/slice index in checker**: `checker.Checker.data_declaration@checker.zig:2895 | return self.more_declarations.constSlot(@as(i64, @intCast(@as(u32, d.more))) - 1).*.at(j);` 0.55; `checker.Checker.symbol_declaration_count@checker.zig:2819 | return rig.rt(self.program.*.bindings.constSlot(@as(i64, @intCast(@as(u32, b.file())))).*.declaration_count_of` 0.53; `checker.Checker.symbol_declaration@checker.zig:2836 | return rig.rt(node_ref(@as(i64, @intCast(@as(u32, b.file()))), rig.rt(self.program.*.bindings.constSlot(@as(i6` 0.51
- **O other (ast index)**: `ast.Ast.parent_child@ast.zig:1246 | const w: u32 = self.words.at(i);` 1.62; `ast.Ast.parent_child@ast.zig:1248 | self.recs.slot(w).*.parent = p;` 1.37; `ast.Ast.parent_list@ast.zig:1263 | self.recs.slot(self.list_nodes.at(k).id).*.parent = p;` 1.12
- **F front-end rule kinds: std**: `__rig_std_prelude.Map(u32,u32).put@__rig_std_prelude.zig:65 | if (self.t.put(rig.take(&__rig_alive_k, k), rig.take(&__rig_alive_v, v))) {` 0.32; `__rig_std_prelude.Set(u32).add@__rig_std_prelude.zig:278 | const added: bool = self.t.add(rig.take(&__rig_alive_k, k));` 0.30; `__rig_std_prelude.Map(checker.CacheKey,u32).put@__rig_std_prelude.zig:65 | if (self.t.put(rig.take(&__rig_alive_k, k), rig.take(&__rig_alive_v, v))) {` 0.21
- **C conversions/overflow elsewhere (checker)**: `checker.Checker.union_front_state@checker.zig:5566 | const effects: i64 = ((((((((((@as(i64, @intCast(@as(u32, self.type_count))) + @as(i64, @intCast(@as(u32, self` 0.73; `checker.node_ref@checker.zig:97409 | return NodeRef{ .file = @as(u32, @intCast(@as(u64, @intCast(@as(i64, f + 1))))), .node = n };` 0.28; `checker.Checker.flow_memo_effect_sum@checker.zig:38233 | return (((((((((((@as(i64, @intCast(@as(u32, self.type_count))) + @as(i64, @intCast(@as(u32, self.signature_co` 0.20
- **F front-end rule kinds: a**: `ast.Ast.new_node@ast.zig:584 | return Node{ .id = @as(u32, @intCast(@as(u64, @intCast(@as(i64, rig.lenOf(self.recs) - 1))))) };` 0.48; `checker.Checker.new_type_list@checker.zig:80226 | const start: u32 = @as(u32, @intCast(@as(u64, @intCast(@as(i64, rig.lenOf(self.store.type_lists))))));` 0.33; `ast.Ast.new_node@ast.zig:582 | self.recs.push(NodeRec{ .kind = __rig_local_kind_93, .keyword = .Unknown, .parent = 0, .data = @as(u32, @intCa` 0.26

## Compiler (full c1; checks = 6.5% of cycles)

std Map/Set/Ordered (innermost frame in the tables): 3.14% of all weighted check branches (zig.integerOverflow 1.98, zig.integerOutOfBounds 0.72, zig.incorrectAlignment 0.30, zig.outOfBounds 0.09, zig.startGreaterThanEnd 0.03, indexPanic 0.00, lenPanic 0.00, rig.table.fullPanic 0.00, zig.integerPartOutOfBounds 0.00), ~0.23% of cycles; counted inside the rows below by their caller

| kind | share of all | share of live | ~% of cycles |
|---|---:|---:|---:|
| H1 handle: index by an id (a Table store covers) | 20.52% | 23.6% | 1.54% |
| (not run) b-built | 13.03% |  | ~0 |
| H3 handle: inside a record (offset/slice; Table alone does not cover) | 11.53% | 13.3% | 0.86% |
| H1 handle: index by an id (other List) | 8.85% | 10.2% | 0.66% |
| L List/slice index in checker | 8.84% | 10.2% | 0.66% |
| Z runtime and Zig std | 7.32% | 8.4% | 0.55% |
| O other (ast index) | 7.21% | 8.3% | 0.54% |
| C conversions/overflow elsewhere (checker) | 3.98% | 4.6% | 0.30% |
| F front-end rule kinds: std | 3.21% | 3.7% | 0.24% |
| F front-end rule kinds: a | 2.85% | 3.3% | 0.21% |
| F front-end rule kinds: b+ | 2.14% | 2.5% | 0.16% |
| F front-end rule kinds: e | 1.65% | 1.9% | 0.12% |
| R conversions/overflow in relation code | 1.38% | 1.6% | 0.10% |
| F front-end rule kinds: hash | 1.38% | 1.6% | 0.10% |
| C conversions/overflow elsewhere (ast) | 1.36% | 1.6% | 0.10% |
| F front-end rule kinds: c2r | 1.26% | 1.5% | 0.09% |
| F front-end rule kinds: a+ | 1.17% | 1.3% | 0.09% |
| F front-end rule kinds: c2p | 0.35% | 0.4% | 0.03% |
| F front-end rule kinds: ctr | 0.32% | 0.4% | 0.02% |
| F front-end rule kinds: c2n | 0.25% | 0.3% | 0.02% |
| O other (ast slice) | 0.21% | 0.2% | 0.02% |
| O other (lexer index) | 0.21% | 0.2% | 0.02% |
| C conversions/overflow elsewhere (core) | 0.15% | 0.2% | 0.01% |
| C conversions/overflow elsewhere (parser) | 0.13% | 0.1% | 0.01% |
| O other (core index) | 0.10% | 0.1% | 0.01% |
| O other (parser index) | 0.09% | 0.1% | 0.01% |
| (not run) cold | 0.09% |  | ~0 |
| O other (jsnum slice) | 0.08% | 0.1% | 0.01% |
| C conversions/overflow elsewhere (lexer) | 0.07% | 0.1% | 0.01% |
| O other (parser slice) | 0.04% | 0.0% | 0.00% |
| F front-end rule kinds: data | 0.04% | 0.0% | 0.00% |
| C conversions/overflow elsewhere (collections) | 0.04% | 0.0% | 0.00% |
| O other (lexer slice) | 0.03% | 0.0% | 0.00% |
| C conversions/overflow elsewhere (jsnum) | 0.03% | 0.0% | 0.00% |
| C conversions/overflow elsewhere (binder) | 0.02% | 0.0% | 0.00% |
| C conversions/overflow elsewhere (compiler) | 0.02% | 0.0% | 0.00% |
| O other (collections index) | 0.02% | 0.0% | 0.00% |
| O other (tspath slice) | 0.02% | 0.0% | 0.00% |
| C conversions/overflow elsewhere (tspath) | 0.01% | 0.0% | 0.00% |
| C conversions/overflow elsewhere (rig) | 0.01% | 0.0% | 0.00% |
| O other (jsnum index) | 0.01% | 0.0% | 0.00% |
| C conversions/overflow elsewhere (__rig_main) | 0.01% | 0.0% | 0.00% |
| L List/slice index in binder | 0.01% | 0.0% | 0.00% |
| C conversions/overflow elsewhere (process) | 0.00% | 0.0% | 0.00% |
| O other (tspath index) | 0.00% | 0.0% | 0.00% |
| L List/slice index in compiler | 0.00% | 0.0% | 0.00% |
| C conversions/overflow elsewhere (diagnostics) | 0.00% | 0.0% | 0.00% |
| O other (diagnostics index) | 0.00% | 0.0% | 0.00% |
| C conversions/overflow elsewhere (printer) | 0.00% | 0.0% | 0.00% |
| O other (packagejson index) | 0.00% | 0.0% | 0.00% |
| O other (module index) | 0.00% | 0.0% | 0.00% |
| O other (core slice) | 0.00% | 0.0% | 0.00% |
| O other (tsoptions index) | 0.00% | 0.0% | 0.00% |
| C conversions/overflow elsewhere (tsoptions) | 0.00% | 0.0% | 0.00% |

- **H1 handle: index by an id (a Table store covers)**: `ast.Ast.kind@ast.zig:446 | return self.recs.at(n.id).kind;` 5.77; `ast.Ast.word_node@ast.zig:922 | return (__rig_rt_178: { var __rig_v_178 = as_node(self.words.at(@as(i64, @intCast(@as(u32, self.recs.at(n.id).` 2.00; `ast.Ast.parent@ast.zig:483 | return (__rig_rt_92: { var __rig_v_92 = as_node(self.recs.at(n.id).parent); _ = &__rig_v_92; break :__rig_rt_9` 1.48
- **H3 handle: inside a record (offset/slice; Table alone does not cover)**: `ast.Ast.word_node@ast.zig:922 | return (__rig_rt_178: { var __rig_v_178 = as_node(self.words.at(@as(i64, @intCast(@as(u32, self.recs.at(n.id).` 4.33; `ast.Ast.word_list@ast.zig:932 | return (__rig_rt_179: { var __rig_v_179 = as_list(self.words.at(@as(i64, @intCast(@as(u32, self.recs.at(n.id).` 1.42; `ast.Ast.parent_list@ast.zig:1263 | self.recs.slot(self.list_nodes.at(k).id).*.parent = p;` 1.22
- **H1 handle: index by an id (other List)**: `ast.Ast.parent_list@ast.zig:1256 | const r = self.lists.at(self.words.at(i));` 1.22; `ast.Binding.declaration_of@ast.zig:18146 | return self.more_nodes.at((@as(i64, @intCast(@as(u32, self.symbol_extras.at(@as(i64, @intCast(@as(u32, extra))` 1.12; `checker.Checker.data_declaration@checker.zig:2895 | return self.more_declarations.constSlot(@as(i64, @intCast(@as(u32, d.more))) - 1).*.at(j);` 0.58
- **L List/slice index in checker**: `checker.Checker.synthetic_index@checker.zig:86450 | if (@as(i64, @intCast(@as(u32, n.node.id))) <= rig.rt(self.program.*.files.constSlot(@as(i64, @as(i64, @intCas` 0.68; `checker.Checker.data_declaration@checker.zig:2895 | return self.more_declarations.constSlot(@as(i64, @intCast(@as(u32, d.more))) - 1).*.at(j);` 0.58; `checker.Checker.symbol_declaration_count@checker.zig:2819 | return rig.rt(self.program.*.bindings.constSlot(@as(i64, @intCast(@as(u32, b.file())))).*.declaration_count_of` 0.57
- **Z runtime and Zig std**: `rig.table.Table(u32,536870912).push@table.zig:215 | ` 0.47; `rig.table.Table(u32,134217728).push@table.zig:215 | ` 0.46; `checker.Checker.new_type_list@checker.zig:80226 | const start: u32 = @as(u32, @intCast(@as(u64, @intCast(@as(i64, rig.lenOf(self.store.type_lists))))));` 0.32
- **O other (ast index)**: `ast.Ast.parent_child@ast.zig:1246 | const w: u32 = self.words.at(i);` 1.77; `ast.Ast.parent_child@ast.zig:1248 | self.recs.slot(w).*.parent = p;` 1.50; `ast.Ast.parent_list@ast.zig:1263 | self.recs.slot(self.list_nodes.at(k).id).*.parent = p;` 1.22
- **C conversions/overflow elsewhere (checker)**: `checker.Checker.union_front_state@checker.zig:5566 | const effects: i64 = ((((((((((@as(i64, @intCast(@as(u32, self.type_count))) + @as(i64, @intCast(@as(u32, self` 0.61; `checker.node_ref@checker.zig:97409 | return NodeRef{ .file = @as(u32, @intCast(@as(u64, @intCast(@as(i64, f + 1))))), .node = n };` 0.41; `checker.Checker.flow_memo_effect_sum@checker.zig:38233 | return (((((((((((@as(i64, @intCast(@as(u32, self.type_count))) + @as(i64, @intCast(@as(u32, self.signature_co` 0.30
- **F front-end rule kinds: std**: `__rig_std_prelude.Set(u32).add@__rig_std_prelude.zig:278 | const added: bool = self.t.add(rig.take(&__rig_alive_k, k));` 0.38; `__rig_std_prelude.Map(u32,u32).put@__rig_std_prelude.zig:65 | if (self.t.put(rig.take(&__rig_alive_k, k), rig.take(&__rig_alive_v, v))) {` 0.22; `__rig_std_prelude.Map(checker.CacheKey,u32).put@__rig_std_prelude.zig:65 | if (self.t.put(rig.take(&__rig_alive_k, k), rig.take(&__rig_alive_v, v))) {` 0.21
- **F front-end rule kinds: a**: `ast.Ast.new_node@ast.zig:584 | return Node{ .id = @as(u32, @intCast(@as(u64, @intCast(@as(i64, rig.lenOf(self.recs) - 1))))) };` 0.49; `checker.Checker.new_type_list@checker.zig:80226 | const start: u32 = @as(u32, @intCast(@as(u64, @intCast(@as(i64, rig.lenOf(self.store.type_lists))))));` 0.32; `ast.Ast.new_node@ast.zig:582 | self.recs.push(NodeRec{ .kind = __rig_local_kind_93, .keyword = .Unknown, .parent = 0, .data = @as(u32, @intCa` 0.27

