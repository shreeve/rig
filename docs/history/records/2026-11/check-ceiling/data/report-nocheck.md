### webpack --noCheck: shares, and cycles at the measured 5.0%

| category | share of all check branches (weighted) | share of live | ~share of c1 cycles | branches | sites | kinds |
|---|---:|---:|---:|---:|---:|---|
| d | 27.6% | 30.7% | 1.53% | 2427 | 313 | index 27.6 |
| d-rec | 7.6% | 8.4% | 0.42% | 712 | 38 | index 4.7, ovf 1.7, slice 1.3 |
| b+ | 8.1% | 9.0% | 0.45% | 305 | 68 | index 6.2, ovf 1.9 |
| b-built | 7.8% |  | ~0 | 566 | 60 | index 7.8 |
| a | 7.6% | 8.5% | 0.42% | 1046 | 37 | conv 7.4, ovf 0.2 |
| a+ | 5.8% | 6.5% | 0.32% | 838 | 17 | conv 5.7, ovf 0.1 |
| c2n | 2.4% | 2.7% | 0.14% | 24 | 3 | index 2.4 |
| c2r | 4.5% | 5.0% | 0.25% | 197 | 58 | slice 3.3, ovf 1.1 |
| c2p | 1.5% | 1.7% | 0.08% | 49 | 2 | index 0.8, ovf 0.7 |
| e | 0.7% | 0.8% | 0.04% | 128 | 39 | index 0.7 |
| hash | 2.2% | 2.4% | 0.12% | 211 | 20 | index 1.4, ovf 0.5, conv 0.3, slice 0.1 |
| ctr | 0.4% | 0.4% | 0.02% | 70 | 10 | ovf 0.4 |
| std | 3.9% | 4.3% | 0.22% | 655 | 126 | index 2.0, ovf 1.2, shift 0.3, conv 0.2 |
| data | 1.1% | 1.3% | 0.06% | 379 | 21 | bytes 0.8, ovf 0.2, index 0.1, slice 0.1 |
| zig | 9.0% | 10.0% | 0.50% | 1068 | 338 | zbounds 3.6, ovf 2.2, zslice 1.7, len 0.9 |
| cold | 2.2% |  | ~0 | 6 | 3 | index 2.2 |
| other | 6.1% | 6.8% | 0.34% | 858 | 404 | index 2.9, ovf 2.0, slice 0.9, conv 0.3 |
| unk | 1.4% | 1.6% | 0.08% | 172 | 46 | index 1.0, conv 0.2, ovf 0.2, slice 0.1 |

Top helpers per category (share of all weighted check branches; Rig source):

- **d**: `Ast.kind` 5.44% (ast/ast.rig:400), `Ast.parent_list` 2.89% (ast/ast.rig:876), `Ast.finish_node` 2.06% (ast/ast.rig:795), `Ast.parent_child` 1.47% (ast/ast.rig:870), `Ast.flags` 1.32% (ast/ast.rig:404), `Ast.set_parent_in_immediate_children` 1.07% (ast/ast.rig:859)
- **d-rec**: `Ast.word_node` 1.83% (ast/ast.rig:676), `Ast.parent_list` 1.45% (ast/ast.rig:876), `Ast.list_node` 1.05% (ast/ast.rig:460), `Ast.word_list` 0.80% (ast/ast.rig:680), `Ast.nodes` 0.60% (ast/ast.rig:430), `Ast.text_of` 0.48% (ast/ast.rig:484)
- **b+**: `Ast.word` 2.47% (ast/ast.rig:444), `Binder.bind_children_of` 2.24% (binder/children_generated.rig:14), `Ast.parent_child` 1.64% (ast/ast.rig:870), `Ast.parent_list` 1.45% (ast/ast.rig:876), `Ast.set_parent_of_children` 0.33% (ast/ast_generated.rig:937)
- **b-built**: `Ast.binary_expression` 2.70% (ast/ast_generated.rig:6198), `Ast.jsdoc_parameter_or_property_tag` 0.73% (ast/ast_generated.rig:6768), `Ast.source_file` 0.65% (ast/ast_generated.rig:6698), `Ast.module_declaration` 0.51% (ast/ast_generated.rig:6703), `Ast.call_expression` 0.46% (ast/ast_generated.rig:6253), `Ast.element_access_expression` 0.31% (ast/ast_generated.rig:6248)
- **a**: `Ast.new_node` 3.87% (ast/ast.rig:501), `Ast.add_text` 0.94% (ast/ast.rig:506), `Ast.add_list` 0.79% (ast/ast.rig:645), `Binding.new_table` 0.37% (ast/binding.rig:137), `Binder.new_flow_list` 0.36% (binder/binder.rig:727), `Binder.new_symbol` 0.31% (binder/binder.rig:333)
- **a+**: `Ast.finish_node` 4.05% (ast/ast.rig:795), `Ast.add_list` 0.91% (ast/ast.rig:645), `Parser.token_piece` 0.44% (parser/jsdoc.rig:1264), `Ast.add_text` 0.30% (ast/ast.rig:506), `Parser.skip_whitespace_or_asterisk` 0.06% (parser/jsdoc.rig:346), `Ids.of` 0.05% (compiler/ids.rig:83)
- **c2n**: `Scanner.char` 2.41% (lexer/scanner.rig:678), `Scanner.scan_js_doc_comment_text_token` 0.02% (lexer/scanner.rig:1613)
- **c2r**: `Scanner.scan` 2.04% (lexer/scanner.rig:770), `Scanner.token_value` 0.81% (lexer/scanner.rig:463), `Scanner.scan_operator` 0.51% (lexer/scanner.rig:844), `Scanner.value_add` 0.32% (lexer/scanner.rig:488), `Scanner.scan_js_doc_token` 0.21% (lexer/scanner.rig:1655), `Scanner.scan_comment` 0.21% (lexer/scanner.rig:1101)
- **c2p**: `Scanner.char_at` 1.50% (lexer/scanner.rig:684)
- **e**: `Ast.expression` 0.11% (ast/ast_generated.rig:7596), `Ast.name` 0.11% (ast/ast_generated.rig:7582), `Ast.modifiers` 0.10% (ast/ast_generated.rig:7589), `Ast.deep_clone` 0.09% (ast/deepclone.rig:22), `Ast.statement_list` 0.07% (ast/ast_generated.rig:7694), `Ast.argument_list` 0.06% (ast/ast_generated.rig:7631)
- **hash**: `Ast.place_name` 0.95% (ast/ast.rig:554), `Binding.table_put` 0.36% (ast/binding.rig:173), `NameTable.place` 0.26% (ast/names.rig:279), `Binding.table_get` 0.20% (ast/binding.rig:154), `Names.rebuild` 0.17% (ast/names.rig:178), `Names.find_in` 0.10% (ast/names.rig:194)
- **ctr**: `make_identifier` 0.18% (parser/parser.rig:155), `Binder.new_symbol` 0.16% (binder/binder.rig:333), `Parser.parse_tag_comments` 0.01% (parser/jsdoc.rig:446), `Parser.find_matching_parameter` 0.01% (parser/reparser.rig:610), `Parser.parse_jsdoc_comment_worker` 0.01% (parser/jsdoc.rig:183), `FileLoader.add_sub_task` 0.00% (compiler/filesparser.rig:318)
- **std**: `long_after` 0.74% (std/utf8.rig:59), `Map(u32,u32).put` 0.46% (?), `find_any` 0.42% (?), `multi_after` 0.39% (std/utf8.rig:43), `order2_cmp_func` 0.22% (?), `partial_insertion_sort_cmp_func` 0.20% (?)
- **data**: `Reader.u32` 0.51% (ast/prebuilt.rig:290), `Scanner.find_comment_close` 0.27% (lexer/scanner.rig:1172), `Reader.list` 0.12% (ast/prebuilt.rig:283), `Reader.int` 0.07% (ast/prebuilt.rig:300), `Reader.u32_list` 0.04% (ast/prebuilt.rig:360), `Reader.nodes` 0.03% (ast/prebuilt.rig:320)
- **zig**: `wyhash.Wyhash.final1` 1.29% (?), `wyhash.Wyhash.read` 1.29% (?), `wyhash.Wyhash.smallKey` 0.97% (?), `runtime.slice` 0.56% (?), `alloc.Heap.alloc` 0.33% (?), `wyhash.Wyhash.hash` 0.32% (?)
- **cold**: `class_end` 2.05% (std/text.rig:100), `find_any` 0.14% (?)
- **other**: `Scanner.skip_ascii_trivia` 1.02% (lexer/scanner.rig:737), `Binding.index_flow_runs` 0.59% (ast/binding.rig:284), `Parser.parse_delimited_list_opt` 0.39% (parser/parser.rig:761), `Scanner.last_line_start_before` 0.34% (lexer/scanner.rig:1188), `Scanner.process_comment_directive` 0.26% (lexer/scanner.rig:1282), `Scanner.scan_js_doc_comment_for_tags` 0.21% (lexer/scanner.rig:609)
- **unk**: `Ast.text` 0.50% (ast/ast.rig:698), `Binder.bind_declaration` 0.22% (binder/binder.rig:848), `Parser.parse_postfix_type_or_higher` 0.06% (parser/parser.rig:2739), `Parser.parse_statement` 0.06% (parser/parser.rig:1108), `Parser.parse_non_array_type` 0.06% (parser/parser.rig:2775), `Scanner.scan_js_doc_token` 0.05% (lexer/scanner.rig:1655)

