	.build_version macos, 15, 0
	.file	1 "/Users/shreeve/.local/share/mise/installs/zig/0.17.0/lib" "std/lang.zig"
	.file	2 "/Users/shreeve/.cache/zig" "b/23b4b8dcf356887f3eb81de45885f1d2/builtin.zig"
	.file	3 "/private/tmp/claude-501/-Users-shreeve-Data-Code-undat/6fff74ce-077f-4bc9-afce-9c419f622ac3/scratchpad/opts/zig" "abi3.zig"
	.section	__TEXT,__text,regular,pure_instructions
	.p2align	2
_abi3.call_value:
Lfunc_begin0:
	.loc	3 12 0
	.cfi_startproc
	stp	x29, x30, [sp, #-16]!
	.cfi_def_cfa_offset 16
	mov	x29, sp
	.cfi_def_cfa w29, 16
	.cfi_offset w30, -8
	.cfi_offset w29, -16
Ltmp0:
	.cfi_def_cfa wsp, 16
	.loc	3 14 6 prologue_end epilogue_begin
	ldp	x29, x30, [sp], #16
	.cfi_def_cfa_offset 0
	.cfi_restore w30
	.cfi_restore w29
	b	_abi3.flat
Ltmp1:
Lfunc_end0:
	.cfi_endproc

	.p2align	2
_abi3.flat:
Lfunc_begin1:
	.loc	3 3 0
	.cfi_startproc
	stp	x29, x30, [sp, #-16]!
	.cfi_def_cfa_offset 16
	mov	x29, sp
	.cfi_def_cfa w29, 16
	.cfi_offset w30, -8
	.cfi_offset w29, -16
Ltmp2:
	.loc	3 4 5 prologue_end
	adrp	x8, _abi3.sink@PAGE
	ldr	x9, [x8, _abi3.sink@PAGEOFF]
	.loc	3 4 69 is_stmt 0
	add	x9, x0, x9
	add	x9, x9, #8
	str	x9, [x8, _abi3.sink@PAGEOFF]
	.cfi_def_cfa wsp, 16
	.loc	3 4 69 epilogue_begin
	ldp	x29, x30, [sp], #16
	.cfi_def_cfa_offset 0
	.cfi_restore w30
	.cfi_restore w29
	ret
Ltmp3:
Lfunc_end1:
	.cfi_endproc

	.p2align	2
_abi3.call_viewed_stored:
Lfunc_begin2:
	.loc	3 10 0 is_stmt 1
	.cfi_startproc
	stp	x29, x30, [sp, #-16]!
	.cfi_def_cfa_offset 16
	mov	x29, sp
	.cfi_def_cfa w29, 16
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	.cfi_def_cfa wsp, 16
Ltmp4:
	.loc	3 10 60 prologue_end epilogue_begin
	ldp	x29, x30, [sp], #16
	.cfi_def_cfa_offset 0
	.cfi_restore w30
	.cfi_restore w29
	b	_abi3.viewed
Ltmp5:
Lfunc_end2:
	.cfi_endproc

	.p2align	2
_abi3.viewed:
Lfunc_begin3:
	.loc	3 6 0
	.cfi_startproc
	stp	x29, x30, [sp, #-16]!
	.cfi_def_cfa_offset 16
	mov	x29, sp
	.cfi_def_cfa w29, 16
	.cfi_offset w30, -8
	.cfi_offset w29, -16
Ltmp6:
	.loc	3 7 5 prologue_end
	adrp	x8, _abi3.sink@PAGE
	ldr	x9, [x8, _abi3.sink@PAGEOFF]
	.loc	3 7 17 is_stmt 0
	ldp	x10, x11, [x0]
	ldrb	w12, [x0, #32]
	.loc	3 7 60
	and	x12, x12, #0x1
	.loc	3 7 98
	ldr	x13, [x0, #24]
	.loc	3 7 32
	add	x10, x10, x11
	.loc	3 7 60
	add	x9, x10, x9
	.loc	3 7 81
	add	x10, x13, x12
	add	x9, x9, x10
	str	x9, [x8, _abi3.sink@PAGEOFF]
	.cfi_def_cfa wsp, 16
	.loc	3 7 81 epilogue_begin
	ldp	x29, x30, [sp], #16
	.cfi_def_cfa_offset 0
	.cfi_restore w30
	.cfi_restore w29
	ret
Ltmp7:
Lfunc_end3:
	.cfi_endproc

.zerofill __DATA,__bss,_abi3.sink,8,3
	.globl	_call_value
_call_value = _abi3.call_value
	.globl	_call_viewed_stored
_call_viewed_stored = _abi3.call_viewed_stored
	.section	__DWARF,__debug_abbrev,regular,debug
Lsection_abbrev:
	.byte	1
	.byte	17
	.byte	1
	.byte	37
	.byte	14
	.byte	19
	.byte	5
	.byte	3
	.byte	14
	.byte	16
	.byte	23
	.byte	27
	.byte	14
	.ascii	"\341\177"
	.byte	25
	.byte	17
	.byte	1
	.byte	18
	.byte	6
	.byte	0
	.byte	0
	.byte	2
	.byte	52
	.byte	0
	.byte	3
	.byte	14
	.byte	73
	.byte	19
	.byte	58
	.byte	11
	.byte	59
	.byte	11
	.byte	110
	.byte	14
	.byte	0
	.byte	0
	.byte	3
	.byte	4
	.byte	1
	.byte	73
	.byte	19
	.byte	3
	.byte	14
	.byte	11
	.byte	11
	.byte	58
	.byte	11
	.byte	59
	.byte	5
	.ascii	"\210\001"
	.byte	15
	.byte	0
	.byte	0
	.byte	4
	.byte	40
	.byte	0
	.byte	3
	.byte	14
	.byte	28
	.byte	15
	.byte	0
	.byte	0
	.byte	5
	.byte	36
	.byte	0
	.byte	3
	.byte	14
	.byte	62
	.byte	11
	.byte	11
	.byte	11
	.byte	0
	.byte	0
	.byte	6
	.byte	52
	.byte	0
	.byte	3
	.byte	14
	.byte	73
	.byte	19
	.byte	58
	.byte	11
	.byte	59
	.byte	11
	.byte	2
	.byte	24
	.byte	110
	.byte	14
	.byte	0
	.byte	0
	.byte	7
	.byte	46
	.byte	1
	.byte	17
	.byte	1
	.byte	18
	.byte	6
	.byte	64
	.byte	24
	.byte	110
	.byte	14
	.byte	3
	.byte	14
	.byte	58
	.byte	11
	.byte	59
	.byte	11
	.byte	73
	.byte	19
	.ascii	"\341\177"
	.byte	25
	.byte	0
	.byte	0
	.byte	8
	.byte	5
	.byte	0
	.byte	2
	.byte	24
	.byte	3
	.byte	14
	.byte	58
	.byte	11
	.byte	59
	.byte	11
	.byte	73
	.byte	19
	.byte	0
	.byte	0
	.byte	9
	.byte	46
	.byte	1
	.byte	17
	.byte	1
	.byte	18
	.byte	6
	.byte	64
	.byte	24
	.byte	110
	.byte	14
	.byte	3
	.byte	14
	.byte	58
	.byte	11
	.byte	59
	.byte	11
	.byte	54
	.byte	11
	.byte	73
	.byte	19
	.ascii	"\341\177"
	.byte	25
	.byte	0
	.byte	0
	.byte	10
	.byte	5
	.byte	0
	.byte	28
	.byte	13
	.byte	3
	.byte	14
	.byte	58
	.byte	11
	.byte	59
	.byte	11
	.byte	73
	.byte	19
	.byte	0
	.byte	0
	.byte	11
	.byte	5
	.byte	0
	.byte	28
	.byte	15
	.byte	3
	.byte	14
	.byte	58
	.byte	11
	.byte	59
	.byte	11
	.byte	73
	.byte	19
	.byte	0
	.byte	0
	.byte	12
	.byte	15
	.byte	0
	.byte	73
	.byte	19
	.byte	3
	.byte	14
	.byte	0
	.byte	0
	.byte	13
	.byte	19
	.byte	1
	.byte	3
	.byte	14
	.byte	11
	.byte	11
	.byte	58
	.byte	11
	.byte	59
	.byte	11
	.ascii	"\210\001"
	.byte	15
	.byte	0
	.byte	0
	.byte	14
	.byte	13
	.byte	0
	.byte	3
	.byte	14
	.byte	73
	.byte	19
	.ascii	"\210\001"
	.byte	15
	.byte	56
	.byte	11
	.byte	0
	.byte	0
	.byte	15
	.byte	19
	.byte	1
	.byte	3
	.byte	14
	.byte	11
	.byte	11
	.ascii	"\210\001"
	.byte	15
	.byte	0
	.byte	0
	.byte	0
	.section	__DWARF,__debug_info,regular,debug
Lsection_info:
Lcu_begin0:
Lset0 = Ldebug_info_end0-Ldebug_info_start0
	.long	Lset0
Ldebug_info_start0:
	.short	4
Lset1 = Lsection_abbrev-Lsection_abbrev
	.long	Lset1
	.byte	8
	.byte	1
	.long	0
	.short	12
	.long	11
Lset2 = Lline_table_start0-Lsection_line
	.long	Lset2
	.long	16

	.quad	Lfunc_begin0
Lset3 = Lfunc_end3-Lfunc_begin0
	.long	Lset3
	.byte	2
	.long	128
	.long	57
	.byte	2
	.byte	6
	.long	171
	.byte	3
	.long	90
	.long	140
	.byte	1
	.byte	1
	.short	974
	.byte	1
	.byte	4
	.long	159
	.byte	0
	.byte	4
	.long	163
	.byte	1
	.byte	4
	.long	167
	.byte	2
	.byte	0
	.byte	5
	.long	156
	.byte	7
	.byte	1
	.byte	6
	.long	191
	.long	122
	.byte	3
	.byte	2
	.byte	9
	.byte	3
	.quad	_abi3.sink
	.long	200
	.byte	5
	.long	196
	.byte	5
	.byte	8
	.byte	7
	.quad	Lfunc_begin0
Lset4 = Lfunc_end0-Lfunc_begin0
	.long	Lset4
	.byte	1
	.byte	109
	.long	221
	.long	210
	.byte	3
	.byte	12
	.long	326

	.byte	8
	.byte	1
	.byte	80
	.long	319
	.byte	3
	.byte	12
	.long	122
	.byte	0
	.byte	9
	.quad	Lfunc_begin1
Lset5 = Lfunc_end1-Lfunc_begin1
	.long	Lset5
	.byte	1
	.byte	109
	.long	242
	.long	237
	.byte	3
	.byte	3
	.byte	3
	.long	326

	.byte	8
	.byte	1
	.byte	80
	.long	321
	.byte	3
	.byte	3
	.long	122
	.byte	10
	.byte	3
	.long	329
	.byte	3
	.byte	3
	.long	122
	.byte	11
	.byte	1
	.long	337
	.byte	3
	.byte	3
	.long	333
	.byte	0
	.byte	7
	.quad	Lfunc_begin2
Lset6 = Lfunc_end2-Lfunc_begin2
	.long	Lset6
	.byte	1
	.byte	109
	.long	271
	.long	252
	.byte	3
	.byte	10
	.long	326

	.byte	8
	.byte	1
	.byte	80
	.long	349
	.byte	3
	.byte	10
	.long	340
	.byte	0
	.byte	7
	.quad	Lfunc_begin3
Lset7 = Lfunc_end3-Lfunc_begin3
	.long	Lset7
	.byte	1
	.byte	109
	.long	302
	.long	295
	.byte	3
	.byte	6
	.long	326

	.byte	8
	.byte	1
	.byte	80
	.long	349
	.byte	3
	.byte	6
	.long	340
	.byte	0
	.byte	5
	.long	314
	.byte	5
	.byte	0
	.byte	5
	.long	344
	.byte	2
	.byte	1
	.byte	12
	.long	349
	.long	353
	.byte	13
	.long	369
	.byte	40
	.byte	3
	.byte	1
	.byte	8
	.byte	14
	.long	321
	.long	122
	.byte	8
	.byte	0
	.byte	14
	.long	329
	.long	122
	.byte	8
	.byte	8
	.byte	14
	.long	378
	.long	403
	.byte	8
	.byte	16
	.byte	14
	.long	337
	.long	333
	.byte	1
	.byte	32
	.byte	0
	.byte	15
	.long	383
	.byte	16
	.byte	8
	.byte	14
	.long	394
	.long	433
	.byte	8
	.byte	0
	.byte	14
	.long	413
	.long	449
	.byte	8
	.byte	8
	.byte	0
	.byte	12
	.long	442
	.long	398
	.byte	5
	.long	410
	.byte	7
	.byte	1
	.byte	5
	.long	417
	.byte	7
	.byte	8
	.byte	0
Ldebug_info_end0:
	.section	__DWARF,__debug_str,regular,debug
Linfo_string:
	.asciz	"zig 0.17.0"
	.asciz	"abi3"
	.asciz	"/private/tmp/claude-501/-Users-shreeve-Data-Code-undat/6fff74ce-077f-4bc9-afce-9c419f622ac3/scratchpad/opts/zig"
	.asciz	"output_mode"
	.asciz	"lang.OutputMode"
	.asciz	"u2"
	.asciz	"Exe"
	.asciz	"Lib"
	.asciz	"Obj"
	.asciz	"builtin.output_mode"
	.asciz	"sink"
	.asciz	"i64"
	.asciz	"abi3.sink"
	.asciz	"call_value"
	.asciz	"abi3.call_value"
	.asciz	"flat"
	.asciz	"abi3.flat"
	.asciz	"call_viewed_stored"
	.asciz	"abi3.call_viewed_stored"
	.asciz	"viewed"
	.asciz	"abi3.viewed"
	.asciz	"void"
	.asciz	"t"
	.asciz	"timeout"
	.asciz	"retries"
	.asciz	"follow"
	.asciz	"bool"
	.asciz	"net"
	.asciz	"*const abi3.Net"
	.asciz	"abi3.Net"
	.asciz	"name"
	.asciz	"[]const u8"
	.asciz	"ptr"
	.asciz	"[*]const u8"
	.asciz	"u8"
	.asciz	"len"
	.asciz	"usize"
	.section	__DWARF,__apple_names,regular,debug
Lnames_begin:
	.long	1212240712
	.short	1
	.short	0
	.long	10
	.long	10
	.long	12
	.long	0
	.long	1
	.short	1
	.short	6
	.long	-1
	.long	0
	.long	1
	.long	2
	.long	3
	.long	4
	.long	6
	.long	-1
	.long	8
	.long	9
	.long	1844606881
	.long	2090724442
	.long	-194335843
	.long	665120724
	.long	583349705
	.long	-1819604071
	.long	698857066
	.long	-946150890
	.long	2090260108
	.long	-1819139737
Lset8 = LNames7-Lnames_begin
	.long	Lset8
Lset9 = LNames0-Lnames_begin
	.long	Lset9
Lset10 = LNames2-Lnames_begin
	.long	Lset10
Lset11 = LNames6-Lnames_begin
	.long	Lset11
Lset12 = LNames8-Lnames_begin
	.long	Lset12
Lset13 = LNames5-Lnames_begin
	.long	Lset13
Lset14 = LNames3-Lnames_begin
	.long	Lset14
Lset15 = LNames9-Lnames_begin
	.long	Lset15
Lset16 = LNames4-Lnames_begin
	.long	Lset16
Lset17 = LNames1-Lnames_begin
	.long	Lset17
LNames7:
	.long	271
	.long	1
	.long	240
	.long	0
LNames0:
	.long	191
	.long	1
	.long	97
	.long	0
LNames2:
	.long	210
	.long	1
	.long	129
	.long	0
LNames6:
	.long	252
	.long	1
	.long	240
	.long	0
LNames8:
	.long	295
	.long	1
	.long	283
	.long	0
LNames5:
	.long	242
	.long	1
	.long	172
	.long	0
LNames3:
	.long	221
	.long	1
	.long	129
	.long	0
LNames9:
	.long	302
	.long	1
	.long	283
	.long	0
LNames4:
	.long	237
	.long	1
	.long	172
	.long	0
LNames1:
	.long	200
	.long	1
	.long	97
	.long	0
	.section	__DWARF,__apple_objc,regular,debug
Lobjc_begin:
	.long	1212240712
	.short	1
	.short	0
	.long	1
	.long	0
	.long	12
	.long	0
	.long	1
	.short	1
	.short	6
	.long	-1
	.section	__DWARF,__apple_namespac,regular,debug
Lnamespac_begin:
	.long	1212240712
	.short	1
	.short	0
	.long	1
	.long	0
	.long	12
	.long	0
	.long	1
	.short	1
	.short	6
	.long	-1
	.section	__DWARF,__apple_types,regular,debug
Ltypes_begin:
	.long	1212240712
	.short	1
	.short	0
	.long	11
	.long	11
	.long	20
	.long	0
	.long	3
	.short	1
	.short	6
	.short	3
	.short	5
	.short	4
	.short	11
	.long	0
	.long	1
	.long	-1
	.long	-1
	.long	2
	.long	4
	.long	8
	.long	-1
	.long	9
	.long	-1
	.long	-1
	.long	30938314
	.long	5863826
	.long	277156213
	.long	356345851
	.long	46322347
	.long	1897091993
	.long	2090120081
	.long	-1114449775
	.long	5863820
	.long	193493176
	.long	2090838615
Lset18 = Ltypes5-Ltypes_begin
	.long	Lset18
Lset19 = Ltypes9-Ltypes_begin
	.long	Lset19
Lset20 = Ltypes10-Ltypes_begin
	.long	Lset20
Lset21 = Ltypes8-Ltypes_begin
	.long	Lset21
Lset22 = Ltypes0-Ltypes_begin
	.long	Lset22
Lset23 = Ltypes6-Ltypes_begin
	.long	Lset23
Lset24 = Ltypes4-Ltypes_begin
	.long	Lset24
Lset25 = Ltypes7-Ltypes_begin
	.long	Lset25
Lset26 = Ltypes1-Ltypes_begin
	.long	Lset26
Lset27 = Ltypes2-Ltypes_begin
	.long	Lset27
Lset28 = Ltypes3-Ltypes_begin
	.long	Lset28
Ltypes5:
	.long	353
	.long	1
	.long	340
	.short	15
	.byte	0
	.long	0
Ltypes9:
	.long	410
	.long	1
	.long	442
	.short	36
	.byte	0
	.long	0
Ltypes10:
	.long	417
	.long	1
	.long	449
	.short	36
	.byte	0
	.long	0
Ltypes8:
	.long	398
	.long	1
	.long	433
	.short	15
	.byte	0
	.long	0
Ltypes0:
	.long	140
	.long	1
	.long	57
	.short	4
	.byte	0
	.long	0
Ltypes6:
	.long	369
	.long	1
	.long	349
	.short	19
	.byte	0
	.long	0
Ltypes4:
	.long	344
	.long	1
	.long	333
	.short	36
	.byte	0
	.long	0
Ltypes7:
	.long	383
	.long	1
	.long	403
	.short	19
	.byte	0
	.long	0
Ltypes1:
	.long	156
	.long	1
	.long	90
	.short	36
	.byte	0
	.long	0
Ltypes2:
	.long	196
	.long	1
	.long	122
	.short	36
	.byte	0
	.long	0
Ltypes3:
	.long	314
	.long	1
	.long	326
	.short	36
	.byte	0
	.long	0
.subsections_via_symbols
	.section	__DWARF,__debug_line,regular,debug
Lsection_line:
Lline_table_start0:
