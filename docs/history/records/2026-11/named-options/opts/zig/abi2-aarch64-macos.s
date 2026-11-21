	.build_version macos, 15, 0
	.file	1 "/Users/shreeve/.local/share/mise/installs/zig/0.17.0/lib" "std/lang.zig"
	.file	2 "/Users/shreeve/.cache/zig" "b/a0a0138a4c6be4cb7f57943e9cdbc392/builtin.zig"
	.file	3 "/private/tmp/claude-501/-Users-shreeve-Data-Code-undat/6fff74ce-077f-4bc9-afce-9c419f622ac3/scratchpad/opts/zig" "abi2.zig"
	.section	__TEXT,__text,regular,pure_instructions
	.p2align	2
_abi2.call_flat_stored:
Lfunc_begin0:
	.loc	3 18 0
	.cfi_startproc
	stp	x29, x30, [sp, #-16]!
	.cfi_def_cfa_offset 16
	mov	x29, sp
	.cfi_def_cfa w29, 16
	.cfi_offset w30, -8
	.cfi_offset w29, -16
Ltmp0:
	.loc	3 19 22 prologue_end
	ldp	x8, x3, [x2]
	.loc	3 19 48 is_stmt 0
	ldrb	w4, [x2, #32]
	.loc	3 19 60
	ldp	x5, x6, [x2, #16]
	.loc	3 19 9
	mov	x2, x8
Ltmp1:
	.cfi_def_cfa wsp, 16
	.loc	3 19 9 epilogue_begin
	ldp	x29, x30, [sp], #16
	.cfi_def_cfa_offset 0
	.cfi_restore w30
	.cfi_restore w29
	b	_abi2.flat
Ltmp2:
Lfunc_end0:
	.cfi_endproc

	.p2align	2
_abi2.flat:
Lfunc_begin1:
	.loc	3 3 0 is_stmt 1
	.cfi_startproc
	stp	x29, x30, [sp, #-16]!
	.cfi_def_cfa_offset 16
	mov	x29, sp
	.cfi_def_cfa w29, 16
	.cfi_offset w30, -8
	.cfi_offset w29, -16
Ltmp3:
	.loc	3 4 5 prologue_end
	adrp	x8, _abi2.sink@PAGE
	ldr	x9, [x8, _abi2.sink@PAGEOFF]
	.loc	3 4 54 is_stmt 0
	add	x10, x1, x0
	add	x11, x2, x3
	add	x10, x10, x11
	and	x11, x4, #0x1
Ltmp4:
	add	x11, x11, x6
Ltmp5:
	.loc	3 4 144
	add	x10, x10, x11
	.loc	3 4 176
	add	x10, x10, x5
	add	x9, x10, x9
	str	x9, [x8, _abi2.sink@PAGEOFF]
	.cfi_def_cfa wsp, 16
	.loc	3 4 176 epilogue_begin
	ldp	x29, x30, [sp], #16
	.cfi_def_cfa_offset 0
	.cfi_restore w30
	.cfi_restore w29
	ret
Ltmp6:
Lfunc_end1:
	.cfi_endproc

	.p2align	2
_abi2.call_grouped_stored:
Lfunc_begin2:
	.loc	3 15 0 is_stmt 1
	.cfi_startproc
	sub	sp, sp, #64
	.cfi_def_cfa_offset 64
	stp	x29, x30, [sp, #48]
	add	x29, sp, #48
	.cfi_def_cfa w29, 16
	.cfi_offset w30, -8
	.cfi_offset w29, -16
Ltmp7:
	.loc	3 16 14 prologue_end
	ldp	q0, q1, [x2]
	stp	q0, q1, [sp]
	ldr	x8, [x2, #32]
	str	x8, [sp, #32]
	.loc	3 16 12 is_stmt 0
	mov	x2, sp
Ltmp8:
	bl	_abi2.grouped
Ltmp9:
	.cfi_def_cfa wsp, 64
	.loc	3 16 12 epilogue_begin
	ldp	x29, x30, [sp, #48]
	add	sp, sp, #64
	.cfi_def_cfa_offset 0
	.cfi_restore w30
	.cfi_restore w29
	ret
Ltmp10:
Lfunc_end2:
	.cfi_endproc

	.p2align	2
_abi2.grouped:
Lfunc_begin3:
	.loc	3 6 0 is_stmt 1
	.cfi_startproc
	stp	x29, x30, [sp, #-16]!
	.cfi_def_cfa_offset 16
	mov	x29, sp
	.cfi_def_cfa w29, 16
	.cfi_offset w30, -8
	.cfi_offset w29, -16
Ltmp11:
	.loc	3 6 53 prologue_end
	ldp	x8, x9, [x2]
	ldp	x10, x11, [x2, #16]
	ldrb	w12, [x2, #32]
	.loc	3 7 5
	adrp	x13, _abi2.sink@PAGE
	ldr	x14, [x13, _abi2.sink@PAGEOFF]
	.loc	3 7 54 is_stmt 0
	add	x15, x1, x0
	.loc	3 7 92
	add	x8, x15, x8
	.loc	3 7 135
	and	x12, x12, #0x1
	.loc	3 7 107
	add	x9, x9, x11
	.loc	3 7 135
	add	x8, x8, x9
	.loc	3 7 156
	add	x9, x10, x14
	.loc	3 7 192
	add	x8, x8, x9
	add	x8, x8, x12
	str	x8, [x13, _abi2.sink@PAGEOFF]
	.cfi_def_cfa wsp, 16
	.loc	3 7 192 epilogue_begin
	ldp	x29, x30, [sp], #16
	.cfi_def_cfa_offset 0
	.cfi_restore w30
	.cfi_restore w29
	ret
Ltmp12:
Lfunc_end3:
	.cfi_endproc

	.p2align	2
_abi2.call_grouped:
Lfunc_begin4:
	.loc	3 12 0 is_stmt 1
	.cfi_startproc
	sub	sp, sp, #64
	.cfi_def_cfa_offset 64
	stp	x29, x30, [sp, #48]
	add	x29, sp, #48
	.cfi_def_cfa w29, 16
	.cfi_offset w30, -8
	.cfi_offset w29, -16
Ltmp13:
	.loc	3 13 75 prologue_end
	stp	x2, x3, [sp, #8]
	strb	w4, [sp, #40]
	stp	x5, x6, [sp, #24]
	.loc	3 13 12 is_stmt 0
	add	x2, sp, #8
Ltmp14:
	bl	_abi2.grouped
Ltmp15:
	.cfi_def_cfa wsp, 64
	.loc	3 13 12 epilogue_begin
	ldp	x29, x30, [sp, #48]
	add	sp, sp, #64
	.cfi_def_cfa_offset 0
	.cfi_restore w30
	.cfi_restore w29
	ret
Ltmp16:
Lfunc_end4:
	.cfi_endproc

	.p2align	2
_abi2.call_flat:
Lfunc_begin5:
	.loc	3 9 0 is_stmt 1
	.cfi_startproc
	stp	x29, x30, [sp, #-16]!
	.cfi_def_cfa_offset 16
	mov	x29, sp
	.cfi_def_cfa w29, 16
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	.cfi_def_cfa wsp, 16
Ltmp17:
	.loc	3 10 9 prologue_end epilogue_begin
	ldp	x29, x30, [sp], #16
	.cfi_def_cfa_offset 0
	.cfi_restore w30
	.cfi_restore w29
	b	_abi2.flat
Ltmp18:
Lfunc_end5:
	.cfi_endproc

.zerofill __DATA,__bss,_abi2.sink,8,3
	.globl	_call_flat_stored
_call_flat_stored = _abi2.call_flat_stored
	.globl	_call_grouped_stored
_call_grouped_stored = _abi2.call_grouped_stored
	.globl	_call_grouped
_call_grouped = _abi2.call_grouped
	.globl	_call_flat
_call_flat = _abi2.call_flat
	.section	__DWARF,__debug_loc,regular,debug
Lsection_debug_loc:
Ldebug_loc0:
Lset0 = Lfunc_begin0-Lfunc_begin0
	.quad	Lset0
Lset1 = Ltmp1-Lfunc_begin0
	.quad	Lset1
	.short	1
	.byte	82
Lset2 = Ltmp1-Lfunc_begin0
	.quad	Lset2
Lset3 = Lfunc_end0-Lfunc_begin0
	.quad	Lset3
	.short	4
	.byte	163
	.byte	1
	.byte	82
	.byte	159
	.quad	0
	.quad	0
Ldebug_loc1:
Lset4 = Ltmp4-Lfunc_begin0
	.quad	Lset4
Lset5 = Ltmp5-Lfunc_begin0
	.quad	Lset5
	.short	1
	.byte	91
	.quad	0
	.quad	0
Ldebug_loc2:
Lset6 = Lfunc_begin2-Lfunc_begin0
	.quad	Lset6
Lset7 = Ltmp9-Lfunc_begin0
	.quad	Lset7
	.short	1
	.byte	80
Lset8 = Ltmp9-Lfunc_begin0
	.quad	Lset8
Lset9 = Lfunc_end2-Lfunc_begin0
	.quad	Lset9
	.short	4
	.byte	163
	.byte	1
	.byte	80
	.byte	159
	.quad	0
	.quad	0
Ldebug_loc3:
Lset10 = Lfunc_begin2-Lfunc_begin0
	.quad	Lset10
Lset11 = Ltmp9-Lfunc_begin0
	.quad	Lset11
	.short	1
	.byte	81
Lset12 = Ltmp9-Lfunc_begin0
	.quad	Lset12
Lset13 = Lfunc_end2-Lfunc_begin0
	.quad	Lset13
	.short	4
	.byte	163
	.byte	1
	.byte	81
	.byte	159
	.quad	0
	.quad	0
Ldebug_loc4:
Lset14 = Lfunc_begin2-Lfunc_begin0
	.quad	Lset14
Lset15 = Ltmp8-Lfunc_begin0
	.quad	Lset15
	.short	1
	.byte	82
Lset16 = Ltmp8-Lfunc_begin0
	.quad	Lset16
Lset17 = Lfunc_end2-Lfunc_begin0
	.quad	Lset17
	.short	4
	.byte	163
	.byte	1
	.byte	82
	.byte	159
	.quad	0
	.quad	0
Ldebug_loc5:
Lset18 = Lfunc_begin4-Lfunc_begin0
	.quad	Lset18
Lset19 = Ltmp15-Lfunc_begin0
	.quad	Lset19
	.short	1
	.byte	80
Lset20 = Ltmp15-Lfunc_begin0
	.quad	Lset20
Lset21 = Lfunc_end4-Lfunc_begin0
	.quad	Lset21
	.short	4
	.byte	163
	.byte	1
	.byte	80
	.byte	159
	.quad	0
	.quad	0
Ldebug_loc6:
Lset22 = Lfunc_begin4-Lfunc_begin0
	.quad	Lset22
Lset23 = Ltmp15-Lfunc_begin0
	.quad	Lset23
	.short	1
	.byte	81
Lset24 = Ltmp15-Lfunc_begin0
	.quad	Lset24
Lset25 = Lfunc_end4-Lfunc_begin0
	.quad	Lset25
	.short	4
	.byte	163
	.byte	1
	.byte	81
	.byte	159
	.quad	0
	.quad	0
Ldebug_loc7:
Lset26 = Lfunc_begin4-Lfunc_begin0
	.quad	Lset26
Lset27 = Ltmp14-Lfunc_begin0
	.quad	Lset27
	.short	1
	.byte	82
Lset28 = Ltmp14-Lfunc_begin0
	.quad	Lset28
Lset29 = Lfunc_end4-Lfunc_begin0
	.quad	Lset29
	.short	4
	.byte	163
	.byte	1
	.byte	82
	.byte	159
	.quad	0
	.quad	0
Ldebug_loc8:
Lset30 = Lfunc_begin4-Lfunc_begin0
	.quad	Lset30
Lset31 = Ltmp15-Lfunc_begin0
	.quad	Lset31
	.short	1
	.byte	83
Lset32 = Ltmp15-Lfunc_begin0
	.quad	Lset32
Lset33 = Lfunc_end4-Lfunc_begin0
	.quad	Lset33
	.short	4
	.byte	163
	.byte	1
	.byte	83
	.byte	159
	.quad	0
	.quad	0
Ldebug_loc9:
Lset34 = Lfunc_begin4-Lfunc_begin0
	.quad	Lset34
Lset35 = Ltmp15-Lfunc_begin0
	.quad	Lset35
	.short	1
	.byte	84
Lset36 = Ltmp15-Lfunc_begin0
	.quad	Lset36
Lset37 = Lfunc_end4-Lfunc_begin0
	.quad	Lset37
	.short	4
	.byte	163
	.byte	1
	.byte	84
	.byte	159
	.quad	0
	.quad	0
Ldebug_loc10:
Lset38 = Lfunc_begin4-Lfunc_begin0
	.quad	Lset38
Lset39 = Ltmp15-Lfunc_begin0
	.quad	Lset39
	.short	1
	.byte	85
Lset40 = Ltmp15-Lfunc_begin0
	.quad	Lset40
Lset41 = Lfunc_end4-Lfunc_begin0
	.quad	Lset41
	.short	4
	.byte	163
	.byte	1
	.byte	85
	.byte	159
	.quad	0
	.quad	0
Ldebug_loc11:
Lset42 = Lfunc_begin4-Lfunc_begin0
	.quad	Lset42
Lset43 = Ltmp15-Lfunc_begin0
	.quad	Lset43
	.short	1
	.byte	86
Lset44 = Ltmp15-Lfunc_begin0
	.quad	Lset44
Lset45 = Lfunc_end4-Lfunc_begin0
	.quad	Lset45
	.short	4
	.byte	163
	.byte	1
	.byte	86
	.byte	159
	.quad	0
	.quad	0
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
	.byte	5
	.byte	0
	.byte	2
	.byte	23
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
	.byte	10
	.byte	15
	.byte	0
	.byte	73
	.byte	19
	.byte	3
	.byte	14
	.byte	0
	.byte	0
	.byte	11
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
	.byte	12
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
	.byte	13
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
Lset46 = Ldebug_info_end0-Ldebug_info_start0
	.long	Lset46
Ldebug_info_start0:
	.short	4
Lset47 = Lsection_abbrev-Lsection_abbrev
	.long	Lset47
	.byte	8
	.byte	1
	.long	0
	.short	12
	.long	11
Lset48 = Lline_table_start0-Lsection_line
	.long	Lset48
	.long	16

	.quad	Lfunc_begin0
Lset49 = Lfunc_end5-Lfunc_begin0
	.long	Lset49
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
	.quad	_abi2.sink
	.long	200
	.byte	5
	.long	196
	.byte	5
	.byte	8
	.byte	7
	.quad	Lfunc_begin0
Lset50 = Lfunc_end0-Lfunc_begin0
	.long	Lset50
	.byte	1
	.byte	109
	.long	227
	.long	210
	.byte	3
	.byte	18
	.long	646

	.byte	8
	.byte	1
	.byte	80
	.long	391
	.byte	3
	.byte	18
	.long	653
	.byte	8
	.byte	1
	.byte	81
	.long	408
	.byte	3
	.byte	18
	.long	669
	.byte	9
Lset51 = Ldebug_loc0-Lsection_debug_loc
	.long	Lset51
	.long	416
	.byte	3
	.byte	18
	.long	676
	.byte	0
	.byte	7
	.quad	Lfunc_begin1
Lset52 = Lfunc_end1-Lfunc_begin1
	.long	Lset52
	.byte	1
	.byte	109
	.long	254
	.long	249
	.byte	3
	.byte	3
	.long	646

	.byte	8
	.byte	1
	.byte	82
	.long	445
	.byte	3
	.byte	3
	.long	122
	.byte	8
	.byte	1
	.byte	83
	.long	453
	.byte	3
	.byte	3
	.long	122
	.byte	9
Lset53 = Ldebug_loc1-Lsection_debug_loc
	.long	Lset53
	.long	485
	.byte	3
	.byte	3
	.long	769
	.byte	0
	.byte	7
	.quad	Lfunc_begin2
Lset54 = Lfunc_end2-Lfunc_begin2
	.long	Lset54
	.byte	1
	.byte	109
	.long	284
	.long	264
	.byte	3
	.byte	15
	.long	646

	.byte	9
Lset55 = Ldebug_loc2-Lsection_debug_loc
	.long	Lset55
	.long	391
	.byte	3
	.byte	15
	.long	653
	.byte	9
Lset56 = Ldebug_loc3-Lsection_debug_loc
	.long	Lset56
	.long	408
	.byte	3
	.byte	15
	.long	669
	.byte	9
Lset57 = Ldebug_loc4-Lsection_debug_loc
	.long	Lset57
	.long	416
	.byte	3
	.byte	15
	.long	676
	.byte	0
	.byte	7
	.quad	Lfunc_begin3
Lset58 = Lfunc_end3-Lfunc_begin3
	.long	Lset58
	.byte	1
	.byte	109
	.long	317
	.long	309
	.byte	3
	.byte	6
	.long	646

	.byte	8
	.byte	2
	.byte	114
	.byte	0
	.long	416
	.byte	3
	.byte	6
	.long	685
	.byte	0
	.byte	7
	.quad	Lfunc_begin4
Lset59 = Lfunc_end4-Lfunc_begin4
	.long	Lset59
	.byte	1
	.byte	109
	.long	343
	.long	330
	.byte	3
	.byte	12
	.long	646

	.byte	9
Lset60 = Ldebug_loc5-Lsection_debug_loc
	.long	Lset60
	.long	391
	.byte	3
	.byte	12
	.long	653
	.byte	9
Lset61 = Ldebug_loc6-Lsection_debug_loc
	.long	Lset61
	.long	408
	.byte	3
	.byte	12
	.long	669
	.byte	9
Lset62 = Ldebug_loc7-Lsection_debug_loc
	.long	Lset62
	.long	497
	.byte	3
	.byte	12
	.long	122
	.byte	9
Lset63 = Ldebug_loc8-Lsection_debug_loc
	.long	Lset63
	.long	499
	.byte	3
	.byte	12
	.long	122
	.byte	9
Lset64 = Ldebug_loc9-Lsection_debug_loc
	.long	Lset64
	.long	501
	.byte	3
	.byte	12
	.long	769
	.byte	9
Lset65 = Ldebug_loc10-Lsection_debug_loc
	.long	Lset65
	.long	503
	.byte	3
	.byte	12
	.long	653
	.byte	9
Lset66 = Ldebug_loc11-Lsection_debug_loc
	.long	Lset66
	.long	505
	.byte	3
	.byte	12
	.long	669
	.byte	0
	.byte	7
	.quad	Lfunc_begin5
Lset67 = Lfunc_end5-Lfunc_begin5
	.long	Lset67
	.byte	1
	.byte	109
	.long	371
	.long	361
	.byte	3
	.byte	9
	.long	646

	.byte	8
	.byte	1
	.byte	80
	.long	391
	.byte	3
	.byte	9
	.long	653
	.byte	8
	.byte	1
	.byte	81
	.long	408
	.byte	3
	.byte	9
	.long	669
	.byte	8
	.byte	1
	.byte	82
	.long	497
	.byte	3
	.byte	9
	.long	122
	.byte	8
	.byte	1
	.byte	83
	.long	499
	.byte	3
	.byte	9
	.long	122
	.byte	8
	.byte	1
	.byte	84
	.long	501
	.byte	3
	.byte	9
	.long	769
	.byte	8
	.byte	1
	.byte	85
	.long	503
	.byte	3
	.byte	9
	.long	653
	.byte	8
	.byte	1
	.byte	86
	.long	505
	.byte	3
	.byte	9
	.long	669
	.byte	0
	.byte	5
	.long	386
	.byte	5
	.byte	0
	.byte	10
	.long	662
	.long	393
	.byte	5
	.long	405
	.byte	7
	.byte	1
	.byte	5
	.long	410
	.byte	7
	.byte	8
	.byte	10
	.long	685
	.long	420
	.byte	11
	.long	436
	.byte	40
	.byte	3
	.byte	1
	.byte	8
	.byte	12
	.long	445
	.long	122
	.byte	8
	.byte	0
	.byte	12
	.long	453
	.long	122
	.byte	8
	.byte	8
	.byte	12
	.long	461
	.long	739
	.byte	8
	.byte	16
	.byte	12
	.long	485
	.long	769
	.byte	1
	.byte	32
	.byte	0
	.byte	13
	.long	466
	.byte	16
	.byte	8
	.byte	12
	.long	477
	.long	653
	.byte	8
	.byte	0
	.byte	12
	.long	481
	.long	669
	.byte	8
	.byte	8
	.byte	0
	.byte	5
	.long	492
	.byte	2
	.byte	1
	.byte	0
Ldebug_info_end0:
	.section	__DWARF,__debug_str,regular,debug
Linfo_string:
	.asciz	"zig 0.17.0"
	.asciz	"abi2"
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
	.asciz	"abi2.sink"
	.asciz	"call_flat_stored"
	.asciz	"abi2.call_flat_stored"
	.asciz	"flat"
	.asciz	"abi2.flat"
	.asciz	"call_grouped_stored"
	.asciz	"abi2.call_grouped_stored"
	.asciz	"grouped"
	.asciz	"abi2.grouped"
	.asciz	"call_grouped"
	.asciz	"abi2.call_grouped"
	.asciz	"call_flat"
	.asciz	"abi2.call_flat"
	.asciz	"void"
	.asciz	"p"
	.asciz	"[*]const u8"
	.asciz	"u8"
	.asciz	"n"
	.asciz	"usize"
	.asciz	"net"
	.asciz	"*const abi2.Net"
	.asciz	"abi2.Net"
	.asciz	"timeout"
	.asciz	"retries"
	.asciz	"name"
	.asciz	"[]const u8"
	.asciz	"ptr"
	.asciz	"len"
	.asciz	"follow"
	.asciz	"bool"
	.asciz	"t"
	.asciz	"r"
	.asciz	"f"
	.asciz	"q"
	.asciz	"m"
	.section	__DWARF,__apple_names,regular,debug
Lnames_begin:
	.long	1212240712
	.short	1
	.short	0
	.long	14
	.long	14
	.long	12
	.long	0
	.long	1
	.short	1
	.short	6
	.long	0
	.long	2
	.long	3
	.long	5
	.long	-1
	.long	6
	.long	7
	.long	9
	.long	-1
	.long	-1
	.long	10
	.long	12
	.long	-1
	.long	13
	.long	1145150706
	.long	-1671206814
	.long	-915326093
	.long	2090724442
	.long	-2058349050
	.long	-1820118301
	.long	-1478876041
	.long	2090260108
	.long	-1858275130
	.long	-6452345
	.long	1593356278
	.long	-1858739464
	.long	-645685817
	.long	242538715
Lset68 = LNames7-Lnames_begin
	.long	Lset68
Lset69 = LNames11-Lnames_begin
	.long	Lset69
Lset70 = LNames13-Lnames_begin
	.long	Lset70
Lset71 = LNames0-Lnames_begin
	.long	Lset71
Lset72 = LNames6-Lnames_begin
	.long	Lset72
Lset73 = LNames3-Lnames_begin
	.long	Lset73
Lset74 = LNames2-Lnames_begin
	.long	Lset74
Lset75 = LNames4-Lnames_begin
	.long	Lset75
Lset76 = LNames1-Lnames_begin
	.long	Lset76
Lset77 = LNames12-Lnames_begin
	.long	Lset77
Lset78 = LNames10-Lnames_begin
	.long	Lset78
Lset79 = LNames5-Lnames_begin
	.long	Lset79
Lset80 = LNames9-Lnames_begin
	.long	Lset80
Lset81 = LNames8-Lnames_begin
	.long	Lset81
LNames7:
	.long	284
	.long	1
	.long	271
	.long	0
LNames11:
	.long	343
	.long	1
	.long	390
	.long	0
LNames13:
	.long	371
	.long	1
	.long	525
	.long	0
LNames0:
	.long	191
	.long	1
	.long	97
	.long	0
LNames6:
	.long	264
	.long	1
	.long	271
	.long	0
LNames3:
	.long	227
	.long	1
	.long	129
	.long	0
LNames2:
	.long	210
	.long	1
	.long	129
	.long	0
LNames4:
	.long	249
	.long	1
	.long	200
	.long	0
LNames1:
	.long	200
	.long	1
	.long	97
	.long	0
LNames12:
	.long	361
	.long	1
	.long	525
	.long	0
LNames10:
	.long	330
	.long	1
	.long	390
	.long	0
LNames5:
	.long	254
	.long	1
	.long	200
	.long	0
LNames9:
	.long	317
	.long	1
	.long	346
	.long	0
LNames8:
	.long	309
	.long	1
	.long	346
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
	.long	29752393
	.long	5863826
	.long	277156213
	.long	356345851
	.long	46322347
	.long	1895906072
	.long	2090120081
	.long	-1114449775
	.long	5863820
	.long	193493176
	.long	2090838615
Lset82 = Ltypes7-Ltypes_begin
	.long	Lset82
Lset83 = Ltypes5-Ltypes_begin
	.long	Lset83
Lset84 = Ltypes6-Ltypes_begin
	.long	Lset84
Lset85 = Ltypes4-Ltypes_begin
	.long	Lset85
Lset86 = Ltypes0-Ltypes_begin
	.long	Lset86
Lset87 = Ltypes8-Ltypes_begin
	.long	Lset87
Lset88 = Ltypes10-Ltypes_begin
	.long	Lset88
Lset89 = Ltypes9-Ltypes_begin
	.long	Lset89
Lset90 = Ltypes1-Ltypes_begin
	.long	Lset90
Lset91 = Ltypes2-Ltypes_begin
	.long	Lset91
Lset92 = Ltypes3-Ltypes_begin
	.long	Lset92
Ltypes7:
	.long	420
	.long	1
	.long	676
	.short	15
	.byte	0
	.long	0
Ltypes5:
	.long	405
	.long	1
	.long	662
	.short	36
	.byte	0
	.long	0
Ltypes6:
	.long	410
	.long	1
	.long	669
	.short	36
	.byte	0
	.long	0
Ltypes4:
	.long	393
	.long	1
	.long	653
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
Ltypes8:
	.long	436
	.long	1
	.long	685
	.short	19
	.byte	0
	.long	0
Ltypes10:
	.long	492
	.long	1
	.long	769
	.short	36
	.byte	0
	.long	0
Ltypes9:
	.long	466
	.long	1
	.long	739
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
	.long	386
	.long	1
	.long	646
	.short	36
	.byte	0
	.long	0
.subsections_via_symbols
	.section	__DWARF,__debug_line,regular,debug
Lsection_line:
Lline_table_start0:
