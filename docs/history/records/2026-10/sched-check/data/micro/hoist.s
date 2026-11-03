	.build_version macos, 27, 0, 1
	.file	1 "/Users/shreeve/.local/share/mise/installs/zig/0.17.0/lib" "std/lang.zig"
	.file	2 "/Users/shreeve/.cache/zig" "b/6a1f05699b110fa9991106270f91f8df/builtin.zig"
	.file	3 "/Users/shreeve/.local/share/mise/installs/zig/0.17.0/lib" "std/Target.zig"
	.file	4 "/Users/shreeve/.local/share/mise/installs/zig/0.17.0/lib" "std/SemanticVersion.zig"
	.file	5 "/Users/shreeve/Data/Code/claude/rig/rig/sched-check-study/micro" "hoist.zig"
	.file	6 "/Users/shreeve/.local/share/mise/installs/zig/0.17.0/lib" "std/Target/aarch64.zig"
	.section	__TEXT,__text,regular,pure_instructions
	.p2align	2
_hoist.sumPure:
Lfunc_begin0:
	.cfi_startproc
	.loc	5 35 17 prologue_end
	ldr	x11, [x0, #8]
	cbz	x11, LBB0_6
Ltmp0:
	.loc	5 0 17 is_stmt 0
	stp	x29, x30, [sp, #-16]!
	.cfi_def_cfa_offset 16
	mov	x29, sp
	.cfi_def_cfa w29, 16
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	mov	x10, #0
	mov	x8, #0
	mov	w9, #1024
Ltmp1:
LBB0_2:
	.loc	5 35 64 is_stmt 1 discriminator 4
	ldr	x12, [x0]
	ldr	x12, [x12, x10, lsl #3]
Ltmp2:
	.loc	5 30 5
	subs	w9, w9, #1
Ltmp3:
	.loc	5 31 9
	b.eq	LBB0_4
Ltmp4:
	.loc	5 0 0 is_stmt 0
	add	x8, x12, x8
Ltmp5:
	.loc	5 35 44 is_stmt 1 discriminator 8
	add	x10, x10, #1
Ltmp6:
	.loc	5 35 17 is_stmt 0
	cmp	x10, x11
	b.lo	LBB0_2
	b	LBB0_5
Ltmp7:
LBB0_4:
	.loc	5 0 17
	mov	x11, x0
Ltmp8:
	.loc	5 31 45 is_stmt 1 discriminator 4
	; InlineAsm Start
	bl	_hoist.cold2
	; InlineAsm End
Ltmp9:
	mov	x9, x0
Ltmp10:
	.loc	5 0 45 is_stmt 0
	mov	x0, x11
Ltmp11:
	.loc	5 35 17 is_stmt 1
	ldr	x11, [x11, #8]
Ltmp12:
	.loc	5 0 0 is_stmt 0
	add	x8, x12, x8
Ltmp13:
	.loc	5 35 44 discriminator 8
	add	x10, x10, #1
Ltmp14:
	.loc	5 35 17
	cmp	x10, x11
	b.lo	LBB0_2
Ltmp15:
LBB0_5:
	.cfi_def_cfa wsp, 16
	.loc	5 0 17
	ldp	x29, x30, [sp], #16
	.cfi_def_cfa_offset 0
	.cfi_restore w30
	.cfi_restore w29
	.loc	5 36 5 is_stmt 1
	mov	x0, x8
	ret
Ltmp16:
LBB0_6:
	mov	x0, #0
Ltmp17:
	ret
Ltmp18:
Lfunc_end0:
	.cfi_endproc

	.p2align	2
_hoist.cold2:
Lfunc_begin1:
	.loc	5 28 0
	.cfi_startproc
	stp	x29, x30, [sp, #-16]!
	.cfi_def_cfa_offset 16
	mov	x29, sp
	.cfi_def_cfa w29, 16
	.cfi_offset w30, -8
	.cfi_offset w29, -16
Ltmp19:
	.loc	5 28 31 prologue_end
	adrp	x8, _hoist.counter@PAGE
	ldr	w9, [x8, _hoist.counter@PAGEOFF]
	add	w9, w9, #1
	str	w9, [x8, _hoist.counter@PAGEOFF]
	.loc	5 28 46 is_stmt 0
	mov	w0, #1024
	.cfi_def_cfa wsp, 16
	.loc	5 28 46 epilogue_begin
	ldp	x29, x30, [sp], #16
	.cfi_def_cfa_offset 0
	.cfi_restore w30
	.cfi_restore w29
	ret
Ltmp20:
Lfunc_end1:
	.cfi_endproc

	.p2align	2
_hoist.sumNone:
Lfunc_begin2:
	.loc	5 23 0 is_stmt 1
	.cfi_startproc
	ldr	x15, [x0, #8]
Ltmp21:
	.loc	5 25 17 prologue_end
	cbz	x15, LBB2_3
Ltmp22:
	.loc	5 0 17 is_stmt 0
	stp	x29, x30, [sp, #-16]!
	.cfi_def_cfa_offset 16
	mov	x29, sp
	.cfi_def_cfa w29, 16
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	.cfi_remember_state
	ldr	x9, [x0]
	.loc	5 25 17
	and	x8, x15, #0x3
	cmp	x15, #4
	b.hs	LBB2_4
Ltmp23:
	.loc	5 0 17
	mov	x10, #0
	mov	x0, #0
Ltmp24:
	.loc	5 25 17
	b	LBB2_8
Ltmp25:
LBB2_3:
	.cfi_def_cfa wsp, 0
	.cfi_same_value w30
	.cfi_same_value w29
	.loc	5 0 17
	mov	x0, #0
Ltmp26:
	.loc	5 26 5 is_stmt 1
	ret
Ltmp27:
LBB2_4:
	.cfi_restore_state
	.loc	5 0 5 is_stmt 0
	mov	x10, #0
	mov	x11, #0
	mov	x12, #0
	mov	x13, #0
	mov	x14, #0
Ltmp28:
	.loc	5 25 17 is_stmt 1
	and	x15, x15, #0xfffffffffffffffc
	neg	x15, x15
	add	x16, x9, #16
Ltmp29:
LBB2_5:
	.loc	5 25 45 is_stmt 0 discriminator 4
	ldp	x17, x0, [x16, #-16]
Ltmp30:
	add	x14, x17, x14
Ltmp31:
	add	x11, x0, x11
Ltmp32:
	ldp	x17, x0, [x16], #32
	add	x12, x17, x12
Ltmp33:
	add	x13, x0, x13
Ltmp34:
	.loc	5 25 17
	sub	x10, x10, #4
Ltmp35:
	cmp	x15, x10
	b.ne	LBB2_5
Ltmp36:
	add	x11, x11, x14
	add	x12, x13, x12
	add	x0, x12, x11
	cbz	x8, LBB2_10
Ltmp37:
	.loc	5 0 17
	neg	x10, x10
Ltmp38:
LBB2_8:
	.loc	5 25 17 is_stmt 1
	add	x9, x9, x10, lsl #3
LBB2_9:
Ltmp39:
	.loc	5 25 45 is_stmt 0 discriminator 4
	ldr	x10, [x9], #8
	add	x0, x10, x0
Ltmp40:
	.loc	5 25 17
	subs	x8, x8, #1
	b.ne	LBB2_9
Ltmp41:
LBB2_10:
	.cfi_def_cfa wsp, 16
	.loc	5 0 17
	ldp	x29, x30, [sp], #16
	.cfi_def_cfa_offset 0
	.cfi_restore w30
	.cfi_restore w29
	.loc	5 26 5 is_stmt 1
	ret
Ltmp42:
Lfunc_end2:
	.cfi_endproc

	.p2align	2
_hoist.sumNoMem:
Lfunc_begin3:
	.cfi_startproc
	.loc	5 20 17 prologue_end
	ldr	x9, [x0, #8]
	cbz	x9, LBB3_6
Ltmp43:
	.loc	5 0 17 is_stmt 0
	stp	x29, x30, [sp, #-16]!
	.cfi_def_cfa_offset 16
	mov	x29, sp
	.cfi_def_cfa w29, 16
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	mov	x10, #0
	mov	x8, #0
	mov	w11, #1024
Ltmp44:
LBB3_2:
	.loc	5 20 65 discriminator 4
	ldr	x12, [x0]
	ldr	x12, [x12, x10, lsl #3]
Ltmp45:
	.loc	5 10 5 is_stmt 1
	subs	w11, w11, #1
Ltmp46:
	.loc	5 11 9
	b.eq	LBB3_4
Ltmp47:
	.loc	5 0 0 is_stmt 0
	add	x8, x12, x8
Ltmp48:
	.loc	5 20 45 is_stmt 1 discriminator 8
	add	x10, x10, #1
Ltmp49:
	.loc	5 20 17 is_stmt 0
	cmp	x10, x9
	b.lo	LBB3_2
	b	LBB3_5
Ltmp50:
LBB3_4:
	.loc	5 11 57 is_stmt 1 discriminator 4
	; InlineAsm Start
	bl	_hoist.cold
	; InlineAsm End
Ltmp51:
	.loc	5 20 17
	ldr	x9, [x0, #8]
	mov	w11, #1024
Ltmp52:
	.loc	5 0 0 is_stmt 0
	add	x8, x12, x8
Ltmp53:
	.loc	5 20 45 discriminator 8
	add	x10, x10, #1
Ltmp54:
	.loc	5 20 17
	cmp	x10, x9
	b.lo	LBB3_2
Ltmp55:
LBB3_5:
	.cfi_def_cfa wsp, 16
	.loc	5 0 17
	ldp	x29, x30, [sp], #16
	.cfi_def_cfa_offset 0
	.cfi_restore w30
	.cfi_restore w29
	.loc	5 21 5 is_stmt 1
	mov	x0, x8
Ltmp56:
	ret
Ltmp57:
LBB3_6:
	mov	x0, #0
Ltmp58:
	ret
Ltmp59:
Lfunc_end3:
	.cfi_endproc

	.p2align	2
_hoist.cold:
Lfunc_begin4:
	.loc	5 4 0
	.cfi_startproc
	stp	x29, x30, [sp, #-16]!
	.cfi_def_cfa_offset 16
	mov	x29, sp
	.cfi_def_cfa w29, 16
	.cfi_offset w30, -8
	.cfi_offset w29, -16
Ltmp60:
	.loc	5 4 31 prologue_end
	adrp	x8, _hoist.counter@PAGE
	ldr	w9, [x8, _hoist.counter@PAGEOFF]
	add	w9, w9, #1
	str	w9, [x8, _hoist.counter@PAGEOFF]
	.cfi_def_cfa wsp, 16
	.loc	5 4 31 epilogue_begin is_stmt 0
	ldp	x29, x30, [sp], #16
	.cfi_def_cfa_offset 0
	.cfi_restore w30
	.cfi_restore w29
	ret
Ltmp61:
Lfunc_end4:
	.cfi_endproc

	.p2align	2
_hoist.sumMem:
Lfunc_begin5:
	.cfi_startproc
	.loc	5 15 17 prologue_end is_stmt 1
	ldr	x9, [x0, #8]
	cbz	x9, LBB5_6
Ltmp62:
	.loc	5 0 17 is_stmt 0
	stp	x29, x30, [sp, #-16]!
	.cfi_def_cfa_offset 16
	mov	x29, sp
	.cfi_def_cfa w29, 16
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	mov	x10, #0
	mov	x8, #0
	mov	w11, #1024
Ltmp63:
LBB5_2:
	.loc	5 15 63 discriminator 4
	ldr	x12, [x0]
	ldr	x12, [x12, x10, lsl #3]
Ltmp64:
	.loc	5 6 5 is_stmt 1
	subs	w11, w11, #1
Ltmp65:
	.loc	5 7 9
	b.eq	LBB5_4
Ltmp66:
	.loc	5 0 0 is_stmt 0
	add	x8, x12, x8
Ltmp67:
	.loc	5 15 43 is_stmt 1 discriminator 8
	add	x10, x10, #1
Ltmp68:
	.loc	5 15 17 is_stmt 0
	cmp	x10, x9
	b.lo	LBB5_2
	b	LBB5_5
Ltmp69:
LBB5_4:
	.loc	5 7 57 is_stmt 1 discriminator 4
	; InlineAsm Start
	bl	_hoist.cold
	; InlineAsm End
Ltmp70:
	.loc	5 15 17
	ldr	x9, [x0, #8]
	mov	w11, #1024
Ltmp71:
	.loc	5 0 0 is_stmt 0
	add	x8, x12, x8
Ltmp72:
	.loc	5 15 43 discriminator 8
	add	x10, x10, #1
Ltmp73:
	.loc	5 15 17
	cmp	x10, x9
	b.lo	LBB5_2
Ltmp74:
LBB5_5:
	.cfi_def_cfa wsp, 16
	.loc	5 0 17
	ldp	x29, x30, [sp], #16
	.cfi_def_cfa_offset 0
	.cfi_restore w30
	.cfi_restore w29
	.loc	5 16 5 is_stmt 1
	mov	x0, x8
Ltmp75:
	ret
Ltmp76:
LBB5_6:
	mov	x0, #0
Ltmp77:
	ret
Ltmp78:
Lfunc_end5:
	.cfi_endproc

.zerofill __DATA,__bss,_hoist.counter,4,2
	.globl	_sumPure
_sumPure = _hoist.sumPure
	.globl	_sumNone
_sumNone = _hoist.sumNone
	.globl	_sumNoMem
_sumNoMem = _hoist.sumNoMem
	.globl	_sumMem
_sumMem = _hoist.sumMem
	.section	__DWARF,__debug_loc,regular,debug
Lsection_debug_loc:
Ldebug_loc0:
Lset0 = Lfunc_begin0-Lfunc_begin0
	.quad	Lset0
Lset1 = Ltmp1-Lfunc_begin0
	.quad	Lset1
	.short	1
	.byte	80
Lset2 = Ltmp9-Lfunc_begin0
	.quad	Lset2
Lset3 = Ltmp15-Lfunc_begin0
	.quad	Lset3
	.short	4
	.byte	163
	.byte	1
	.byte	80
	.byte	159
Lset4 = Ltmp16-Lfunc_begin0
	.quad	Lset4
Lset5 = Ltmp17-Lfunc_begin0
	.quad	Lset5
	.short	1
	.byte	80
Lset6 = Ltmp17-Lfunc_begin0
	.quad	Lset6
Lset7 = Lfunc_end0-Lfunc_begin0
	.quad	Lset7
	.short	4
	.byte	163
	.byte	1
	.byte	80
	.byte	159
	.quad	0
	.quad	0
Ldebug_loc1:
Lset8 = Lfunc_begin0-Lfunc_begin0
	.quad	Lset8
Lset9 = Ltmp1-Lfunc_begin0
	.quad	Lset9
	.short	4
	.byte	16
	.byte	128
	.byte	8
	.byte	159
Lset10 = Ltmp1-Lfunc_begin0
	.quad	Lset10
Lset11 = Ltmp16-Lfunc_begin0
	.quad	Lset11
	.short	1
	.byte	89
Lset12 = Ltmp16-Lfunc_begin0
	.quad	Lset12
Lset13 = Lfunc_end0-Lfunc_begin0
	.quad	Lset13
	.short	4
	.byte	16
	.byte	128
	.byte	8
	.byte	159
	.quad	0
	.quad	0
Ldebug_loc2:
Lset14 = Lfunc_begin0-Lfunc_begin0
	.quad	Lset14
Lset15 = Ltmp1-Lfunc_begin0
	.quad	Lset15
	.short	2
	.byte	48
	.byte	159
Lset16 = Ltmp1-Lfunc_begin0
	.quad	Lset16
Lset17 = Ltmp2-Lfunc_begin0
	.quad	Lset17
	.short	1
	.byte	88
Lset18 = Ltmp5-Lfunc_begin0
	.quad	Lset18
Lset19 = Ltmp7-Lfunc_begin0
	.quad	Lset19
	.short	1
	.byte	88
Lset20 = Ltmp13-Lfunc_begin0
	.quad	Lset20
Lset21 = Ltmp16-Lfunc_begin0
	.quad	Lset21
	.short	1
	.byte	88
Lset22 = Ltmp16-Lfunc_begin0
	.quad	Lset22
Lset23 = Lfunc_end0-Lfunc_begin0
	.quad	Lset23
	.short	2
	.byte	48
	.byte	159
	.quad	0
	.quad	0
Ldebug_loc3:
Lset24 = Lfunc_begin0-Lfunc_begin0
	.quad	Lset24
Lset25 = Ltmp1-Lfunc_begin0
	.quad	Lset25
	.short	2
	.byte	48
	.byte	159
Lset26 = Ltmp1-Lfunc_begin0
	.quad	Lset26
Lset27 = Ltmp16-Lfunc_begin0
	.quad	Lset27
	.short	1
	.byte	90
Lset28 = Ltmp16-Lfunc_begin0
	.quad	Lset28
Lset29 = Lfunc_end0-Lfunc_begin0
	.quad	Lset29
	.short	2
	.byte	48
	.byte	159
	.quad	0
	.quad	0
Ldebug_loc4:
Lset30 = Lfunc_begin2-Lfunc_begin0
	.quad	Lset30
Lset31 = Ltmp24-Lfunc_begin0
	.quad	Lset31
	.short	1
	.byte	80
Lset32 = Ltmp24-Lfunc_begin0
	.quad	Lset32
Lset33 = Ltmp25-Lfunc_begin0
	.quad	Lset33
	.short	4
	.byte	163
	.byte	1
	.byte	80
	.byte	159
Lset34 = Ltmp25-Lfunc_begin0
	.quad	Lset34
Lset35 = Ltmp26-Lfunc_begin0
	.quad	Lset35
	.short	1
	.byte	80
Lset36 = Ltmp26-Lfunc_begin0
	.quad	Lset36
Lset37 = Ltmp27-Lfunc_begin0
	.quad	Lset37
	.short	4
	.byte	163
	.byte	1
	.byte	80
	.byte	159
Lset38 = Ltmp27-Lfunc_begin0
	.quad	Lset38
Lset39 = Ltmp29-Lfunc_begin0
	.quad	Lset39
	.short	1
	.byte	80
Lset40 = Ltmp30-Lfunc_begin0
	.quad	Lset40
Lset41 = Ltmp36-Lfunc_begin0
	.quad	Lset41
	.short	4
	.byte	163
	.byte	1
	.byte	80
	.byte	159
	.quad	0
	.quad	0
Ldebug_loc5:
Lset42 = Lfunc_begin2-Lfunc_begin0
	.quad	Lset42
Lset43 = Ltmp29-Lfunc_begin0
	.quad	Lset43
	.short	2
	.byte	48
	.byte	159
Lset44 = Ltmp29-Lfunc_begin0
	.quad	Lset44
Lset45 = Ltmp31-Lfunc_begin0
	.quad	Lset45
	.short	1
	.byte	94
Lset46 = Ltmp31-Lfunc_begin0
	.quad	Lset46
Lset47 = Ltmp32-Lfunc_begin0
	.quad	Lset47
	.short	1
	.byte	91
Lset48 = Ltmp32-Lfunc_begin0
	.quad	Lset48
Lset49 = Ltmp33-Lfunc_begin0
	.quad	Lset49
	.short	1
	.byte	92
Lset50 = Ltmp33-Lfunc_begin0
	.quad	Lset50
Lset51 = Ltmp38-Lfunc_begin0
	.quad	Lset51
	.short	1
	.byte	93
Lset52 = Ltmp39-Lfunc_begin0
	.quad	Lset52
Lset53 = Ltmp41-Lfunc_begin0
	.quad	Lset53
	.short	1
	.byte	80
	.quad	0
	.quad	0
Ldebug_loc6:
Lset54 = Lfunc_begin2-Lfunc_begin0
	.quad	Lset54
Lset55 = Ltmp29-Lfunc_begin0
	.quad	Lset55
	.short	2
	.byte	48
	.byte	159
Lset56 = Ltmp29-Lfunc_begin0
	.quad	Lset56
Lset57 = Ltmp31-Lfunc_begin0
	.quad	Lset57
	.short	9
	.byte	122
	.byte	0
	.byte	17
	.byte	124
	.byte	27
	.byte	17
	.byte	4
	.byte	30
	.byte	159
Lset58 = Ltmp31-Lfunc_begin0
	.quad	Lset58
Lset59 = Ltmp32-Lfunc_begin0
	.quad	Lset59
	.short	5
	.byte	122
	.byte	0
	.byte	49
	.byte	33
	.byte	159
Lset60 = Ltmp32-Lfunc_begin0
	.quad	Lset60
Lset61 = Ltmp33-Lfunc_begin0
	.quad	Lset61
	.short	5
	.byte	122
	.byte	0
	.byte	50
	.byte	33
	.byte	159
Lset62 = Ltmp33-Lfunc_begin0
	.quad	Lset62
Lset63 = Ltmp34-Lfunc_begin0
	.quad	Lset63
	.short	5
	.byte	122
	.byte	0
	.byte	51
	.byte	33
	.byte	159
Lset64 = Ltmp34-Lfunc_begin0
	.quad	Lset64
Lset65 = Ltmp35-Lfunc_begin0
	.quad	Lset65
	.short	12
	.byte	122
	.byte	0
	.byte	17
	.byte	124
	.byte	27
	.byte	17
	.byte	4
	.byte	30
	.byte	17
	.byte	4
	.byte	34
	.byte	159
	.quad	0
	.quad	0
Ldebug_loc7:
Lset66 = Lfunc_begin3-Lfunc_begin0
	.quad	Lset66
Lset67 = Ltmp56-Lfunc_begin0
	.quad	Lset67
	.short	1
	.byte	80
Lset68 = Ltmp56-Lfunc_begin0
	.quad	Lset68
Lset69 = Ltmp57-Lfunc_begin0
	.quad	Lset69
	.short	4
	.byte	163
	.byte	1
	.byte	80
	.byte	159
Lset70 = Ltmp57-Lfunc_begin0
	.quad	Lset70
Lset71 = Ltmp58-Lfunc_begin0
	.quad	Lset71
	.short	1
	.byte	80
Lset72 = Ltmp58-Lfunc_begin0
	.quad	Lset72
Lset73 = Lfunc_end3-Lfunc_begin0
	.quad	Lset73
	.short	4
	.byte	163
	.byte	1
	.byte	80
	.byte	159
	.quad	0
	.quad	0
Ldebug_loc8:
Lset74 = Lfunc_begin3-Lfunc_begin0
	.quad	Lset74
Lset75 = Ltmp44-Lfunc_begin0
	.quad	Lset75
	.short	4
	.byte	16
	.byte	128
	.byte	8
	.byte	159
Lset76 = Ltmp44-Lfunc_begin0
	.quad	Lset76
Lset77 = Ltmp50-Lfunc_begin0
	.quad	Lset77
	.short	1
	.byte	91
Lset78 = Ltmp50-Lfunc_begin0
	.quad	Lset78
Lset79 = Ltmp53-Lfunc_begin0
	.quad	Lset79
	.short	4
	.byte	16
	.byte	128
	.byte	8
	.byte	159
Lset80 = Ltmp53-Lfunc_begin0
	.quad	Lset80
Lset81 = Ltmp57-Lfunc_begin0
	.quad	Lset81
	.short	1
	.byte	91
Lset82 = Ltmp57-Lfunc_begin0
	.quad	Lset82
Lset83 = Lfunc_end3-Lfunc_begin0
	.quad	Lset83
	.short	4
	.byte	16
	.byte	128
	.byte	8
	.byte	159
	.quad	0
	.quad	0
Ldebug_loc9:
Lset84 = Lfunc_begin3-Lfunc_begin0
	.quad	Lset84
Lset85 = Ltmp44-Lfunc_begin0
	.quad	Lset85
	.short	2
	.byte	48
	.byte	159
Lset86 = Ltmp44-Lfunc_begin0
	.quad	Lset86
Lset87 = Ltmp45-Lfunc_begin0
	.quad	Lset87
	.short	1
	.byte	88
Lset88 = Ltmp48-Lfunc_begin0
	.quad	Lset88
Lset89 = Ltmp50-Lfunc_begin0
	.quad	Lset89
	.short	1
	.byte	88
Lset90 = Ltmp53-Lfunc_begin0
	.quad	Lset90
Lset91 = Ltmp57-Lfunc_begin0
	.quad	Lset91
	.short	1
	.byte	88
Lset92 = Ltmp57-Lfunc_begin0
	.quad	Lset92
Lset93 = Lfunc_end3-Lfunc_begin0
	.quad	Lset93
	.short	2
	.byte	48
	.byte	159
	.quad	0
	.quad	0
Ldebug_loc10:
Lset94 = Lfunc_begin3-Lfunc_begin0
	.quad	Lset94
Lset95 = Ltmp44-Lfunc_begin0
	.quad	Lset95
	.short	2
	.byte	48
	.byte	159
Lset96 = Ltmp44-Lfunc_begin0
	.quad	Lset96
Lset97 = Ltmp57-Lfunc_begin0
	.quad	Lset97
	.short	1
	.byte	90
Lset98 = Ltmp57-Lfunc_begin0
	.quad	Lset98
Lset99 = Lfunc_end3-Lfunc_begin0
	.quad	Lset99
	.short	2
	.byte	48
	.byte	159
	.quad	0
	.quad	0
Ldebug_loc11:
Lset100 = Lfunc_begin5-Lfunc_begin0
	.quad	Lset100
Lset101 = Ltmp75-Lfunc_begin0
	.quad	Lset101
	.short	1
	.byte	80
Lset102 = Ltmp75-Lfunc_begin0
	.quad	Lset102
Lset103 = Ltmp76-Lfunc_begin0
	.quad	Lset103
	.short	4
	.byte	163
	.byte	1
	.byte	80
	.byte	159
Lset104 = Ltmp76-Lfunc_begin0
	.quad	Lset104
Lset105 = Ltmp77-Lfunc_begin0
	.quad	Lset105
	.short	1
	.byte	80
Lset106 = Ltmp77-Lfunc_begin0
	.quad	Lset106
Lset107 = Lfunc_end5-Lfunc_begin0
	.quad	Lset107
	.short	4
	.byte	163
	.byte	1
	.byte	80
	.byte	159
	.quad	0
	.quad	0
Ldebug_loc12:
Lset108 = Lfunc_begin5-Lfunc_begin0
	.quad	Lset108
Lset109 = Ltmp63-Lfunc_begin0
	.quad	Lset109
	.short	4
	.byte	16
	.byte	128
	.byte	8
	.byte	159
Lset110 = Ltmp63-Lfunc_begin0
	.quad	Lset110
Lset111 = Ltmp69-Lfunc_begin0
	.quad	Lset111
	.short	1
	.byte	91
Lset112 = Ltmp69-Lfunc_begin0
	.quad	Lset112
Lset113 = Ltmp72-Lfunc_begin0
	.quad	Lset113
	.short	4
	.byte	16
	.byte	128
	.byte	8
	.byte	159
Lset114 = Ltmp72-Lfunc_begin0
	.quad	Lset114
Lset115 = Ltmp76-Lfunc_begin0
	.quad	Lset115
	.short	1
	.byte	91
Lset116 = Ltmp76-Lfunc_begin0
	.quad	Lset116
Lset117 = Lfunc_end5-Lfunc_begin0
	.quad	Lset117
	.short	4
	.byte	16
	.byte	128
	.byte	8
	.byte	159
	.quad	0
	.quad	0
Ldebug_loc13:
Lset118 = Lfunc_begin5-Lfunc_begin0
	.quad	Lset118
Lset119 = Ltmp63-Lfunc_begin0
	.quad	Lset119
	.short	2
	.byte	48
	.byte	159
Lset120 = Ltmp63-Lfunc_begin0
	.quad	Lset120
Lset121 = Ltmp64-Lfunc_begin0
	.quad	Lset121
	.short	1
	.byte	88
Lset122 = Ltmp67-Lfunc_begin0
	.quad	Lset122
Lset123 = Ltmp69-Lfunc_begin0
	.quad	Lset123
	.short	1
	.byte	88
Lset124 = Ltmp72-Lfunc_begin0
	.quad	Lset124
Lset125 = Ltmp76-Lfunc_begin0
	.quad	Lset125
	.short	1
	.byte	88
Lset126 = Ltmp76-Lfunc_begin0
	.quad	Lset126
Lset127 = Lfunc_end5-Lfunc_begin0
	.quad	Lset127
	.short	2
	.byte	48
	.byte	159
	.quad	0
	.quad	0
Ldebug_loc14:
Lset128 = Lfunc_begin5-Lfunc_begin0
	.quad	Lset128
Lset129 = Ltmp63-Lfunc_begin0
	.quad	Lset129
	.short	2
	.byte	48
	.byte	159
Lset130 = Ltmp63-Lfunc_begin0
	.quad	Lset130
Lset131 = Ltmp76-Lfunc_begin0
	.quad	Lset131
	.short	1
	.byte	90
Lset132 = Ltmp76-Lfunc_begin0
	.quad	Lset132
Lset133 = Lfunc_end5-Lfunc_begin0
	.quad	Lset133
	.short	2
	.byte	48
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
	.byte	5
	.byte	110
	.byte	14
	.byte	0
	.byte	0
	.byte	7
	.byte	36
	.byte	1
	.byte	3
	.byte	14
	.byte	62
	.byte	11
	.byte	11
	.byte	11
	.byte	0
	.byte	0
	.byte	8
	.byte	19
	.byte	1
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
	.byte	9
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
	.byte	10
	.byte	1
	.byte	1
	.byte	73
	.byte	19
	.byte	3
	.byte	14
	.byte	0
	.byte	0
	.byte	11
	.byte	33
	.byte	0
	.byte	73
	.byte	19
	.byte	55
	.byte	11
	.byte	0
	.byte	0
	.byte	12
	.byte	36
	.byte	0
	.byte	3
	.byte	14
	.byte	11
	.byte	11
	.byte	62
	.byte	11
	.byte	0
	.byte	0
	.byte	13
	.byte	15
	.byte	0
	.byte	73
	.byte	19
	.byte	3
	.byte	14
	.byte	0
	.byte	0
	.byte	14
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
	.byte	15
	.byte	22
	.byte	0
	.byte	73
	.byte	19
	.byte	3
	.byte	14
	.byte	11
	.byte	11
	.byte	0
	.byte	0
	.byte	16
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
	.byte	17
	.byte	23
	.byte	1
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
	.byte	18
	.byte	13
	.byte	0
	.byte	3
	.byte	14
	.byte	73
	.byte	19
	.byte	56
	.byte	11
	.byte	0
	.byte	0
	.byte	19
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
	.byte	11
	.ascii	"\210\001"
	.byte	15
	.byte	0
	.byte	0
	.byte	20
	.byte	19
	.byte	1
	.byte	3
	.byte	14
	.byte	11
	.byte	5
	.byte	58
	.byte	11
	.byte	59
	.byte	11
	.ascii	"\210\001"
	.byte	15
	.byte	0
	.byte	0
	.byte	21
	.byte	19
	.byte	1
	.byte	3
	.byte	14
	.byte	11
	.byte	5
	.byte	58
	.byte	11
	.byte	59
	.byte	5
	.ascii	"\210\001"
	.byte	15
	.byte	0
	.byte	0
	.byte	22
	.byte	23
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
	.byte	23
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
	.byte	24
	.byte	46
	.byte	0
	.byte	110
	.byte	14
	.byte	3
	.byte	14
	.byte	58
	.byte	11
	.byte	59
	.byte	11
	.ascii	"\341\177"
	.byte	25
	.byte	32
	.byte	11
	.byte	0
	.byte	0
	.byte	25
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
	.byte	26
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
	.byte	27
	.byte	52
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
	.byte	28
	.byte	29
	.byte	0
	.byte	49
	.byte	19
	.byte	85
	.byte	23
	.byte	88
	.byte	11
	.byte	89
	.byte	11
	.byte	87
	.byte	11
	.byte	0
	.byte	0
	.byte	29
	.byte	46
	.byte	0
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
	.byte	0
	.section	__DWARF,__debug_info,regular,debug
Lsection_info:
Lcu_begin0:
Lset134 = Ldebug_info_end0-Ldebug_info_start0
	.long	Lset134
Ldebug_info_start0:
	.short	4
Lset135 = Lsection_abbrev-Lsection_abbrev
	.long	Lset135
	.byte	8
	.byte	1
	.long	0
	.short	12
	.long	11
Lset136 = Lline_table_start0-Lsection_line
	.long	Lset136
	.long	17

	.quad	Lfunc_begin0
Lset137 = Lfunc_end5-Lfunc_begin0
	.long	Lset137
	.byte	2
	.long	81
	.long	57
	.byte	2
	.byte	6
	.long	124
	.byte	3
	.long	90
	.long	93
	.byte	1
	.byte	1
	.short	974
	.byte	1
	.byte	4
	.long	112
	.byte	0
	.byte	4
	.long	116
	.byte	1
	.byte	4
	.long	120
	.byte	2
	.byte	0
	.byte	5
	.long	109
	.byte	7
	.byte	1
	.byte	6
	.long	144
	.long	120
	.byte	3
	.short	1250
	.long	232
	.byte	7
	.long	150
	.byte	5
	.byte	0
	.byte	8
	.long	169
	.byte	48
	.byte	3
	.short	1241
	.byte	8
	.byte	9
	.long	192
	.long	143
	.byte	8
	.byte	0
	.byte	0
	.byte	0
	.byte	10
	.long	159
	.long	197
	.byte	11
	.long	166
	.byte	6
	.byte	0
	.byte	5
	.long	206
	.byte	7
	.byte	8
	.byte	12
	.long	212
	.byte	8
	.byte	7
	.byte	2
	.long	261
	.long	188
	.byte	2
	.byte	14
	.long	882
	.byte	8
	.long	265
	.byte	64
	.byte	3
	.short	1210
	.byte	8
	.byte	9
	.long	276
	.long	657
	.byte	8
	.byte	0
	.byte	8
	.long	306
	.byte	80
	.byte	3
	.short	2033
	.byte	8
	.byte	9
	.long	323
	.long	666
	.byte	8
	.byte	0
	.byte	9
	.long	362
	.long	712
	.byte	8
	.byte	16
	.byte	9
	.long	413
	.long	120
	.byte	8
	.byte	32
	.byte	0
	.byte	9
	.long	413
	.long	120
	.byte	8
	.byte	8
	.byte	9
	.long	422
	.long	275
	.byte	1
	.byte	56
	.byte	3
	.long	761
	.long	427
	.byte	1
	.byte	3
	.short	1362
	.byte	1
	.byte	4
	.long	446
	.byte	0
	.byte	4
	.long	454
	.byte	1
	.byte	4
	.long	465
	.byte	2
	.byte	4
	.long	471
	.byte	3
	.byte	4
	.long	478
	.byte	4
	.byte	4
	.long	482
	.byte	5
	.byte	4
	.long	488
	.byte	6
	.byte	4
	.long	492
	.byte	7
	.byte	4
	.long	498
	.byte	8
	.byte	4
	.long	502
	.byte	9
	.byte	4
	.long	508
	.byte	10
	.byte	4
	.long	514
	.byte	11
	.byte	4
	.long	519
	.byte	12
	.byte	4
	.long	524
	.byte	13
	.byte	4
	.long	532
	.byte	14
	.byte	4
	.long	537
	.byte	15
	.byte	4
	.long	544
	.byte	16
	.byte	4
	.long	552
	.byte	17
	.byte	4
	.long	556
	.byte	18
	.byte	4
	.long	562
	.byte	19
	.byte	4
	.long	574
	.byte	20
	.byte	4
	.long	586
	.byte	21
	.byte	4
	.long	591
	.byte	22
	.byte	4
	.long	596
	.byte	23
	.byte	4
	.long	607
	.byte	24
	.byte	4
	.long	620
	.byte	25
	.byte	4
	.long	625
	.byte	26
	.byte	4
	.long	632
	.byte	27
	.byte	4
	.long	639
	.byte	28
	.byte	4
	.long	648
	.byte	29
	.byte	4
	.long	655
	.byte	30
	.byte	4
	.long	661
	.byte	31
	.byte	4
	.long	669
	.byte	32
	.byte	4
	.long	674
	.byte	33
	.byte	4
	.long	682
	.byte	34
	.byte	4
	.long	692
	.byte	35
	.byte	4
	.long	702
	.byte	36
	.byte	4
	.long	714
	.byte	37
	.byte	4
	.long	724
	.byte	38
	.byte	4
	.long	732
	.byte	39
	.byte	4
	.long	742
	.byte	40
	.byte	4
	.long	750
	.byte	41
	.byte	4
	.long	760
	.byte	42
	.byte	4
	.long	766
	.byte	43
	.byte	4
	.long	769
	.byte	44
	.byte	4
	.long	774
	.byte	45
	.byte	4
	.long	780
	.byte	46
	.byte	4
	.long	788
	.byte	47
	.byte	4
	.long	795
	.byte	48
	.byte	4
	.long	803
	.byte	49
	.byte	4
	.long	811
	.byte	50
	.byte	4
	.long	817
	.byte	51
	.byte	4
	.long	825
	.byte	52
	.byte	4
	.long	828
	.byte	53
	.byte	4
	.long	835
	.byte	54
	.byte	4
	.long	842
	.byte	55
	.byte	4
	.long	849
	.byte	56
	.byte	4
	.long	853
	.byte	57
	.byte	4
	.long	860
	.byte	58
	.byte	4
	.long	866
	.byte	59
	.byte	4
	.long	873
	.byte	60
	.byte	0
	.byte	0
	.byte	13
	.long	209
	.long	282
	.byte	14
	.long	328
	.byte	16
	.byte	8
	.byte	9
	.long	339
	.long	696
	.byte	8
	.byte	0
	.byte	9
	.long	358
	.long	159
	.byte	8
	.byte	8
	.byte	0
	.byte	13
	.long	705
	.long	343
	.byte	5
	.long	355
	.byte	7
	.byte	1
	.byte	15
	.long	722
	.long	372
	.byte	16
	.byte	14
	.long	386
	.byte	16
	.byte	8
	.byte	9
	.long	339
	.long	752
	.byte	8
	.byte	0
	.byte	9
	.long	358
	.long	159
	.byte	8
	.byte	8
	.byte	0
	.byte	13
	.long	705
	.long	399
	.byte	5
	.long	443
	.byte	7
	.byte	1
	.byte	2
	.long	894
	.long	783
	.byte	2
	.byte	114
	.long	1751
	.byte	16
	.long	897
	.byte	184
	.byte	3
	.byte	14
	.byte	8
	.byte	9
	.long	907
	.long	803
	.byte	8
	.byte	0
	.byte	17
	.long	921
	.byte	176
	.byte	3
	.short	388
	.byte	8
	.byte	18
	.long	944
	.long	1554
	.byte	0
	.byte	18
	.long	954
	.long	1561
	.byte	0
	.byte	18
	.long	1047
	.long	864
	.byte	0
	.byte	18
	.long	1091
	.long	897
	.byte	0
	.byte	18
	.long	1137
	.long	1206
	.byte	0
	.byte	0
	.byte	8
	.long	1052
	.byte	168
	.byte	3
	.short	332
	.byte	8
	.byte	9
	.long	1079
	.long	1561
	.byte	8
	.byte	0
	.byte	9
	.long	1085
	.long	1593
	.byte	8
	.byte	112
	.byte	0
	.byte	8
	.long	1097
	.byte	176
	.byte	3
	.short	347
	.byte	8
	.byte	9
	.long	1079
	.long	1561
	.byte	8
	.byte	0
	.byte	9
	.long	1085
	.long	1593
	.byte	8
	.byte	112
	.byte	9
	.long	1125
	.long	1668
	.byte	4
	.byte	168
	.byte	0
	.byte	19
	.long	1668
	.long	1145
	.byte	4
	.byte	3
	.byte	232
	.byte	4
	.byte	4
	.long	1170
	.ascii	"\200\200\200 "
	.byte	4
	.long	1174
	.ascii	"\200\200\200("
	.byte	4
	.long	1180
	.ascii	"\200\200\204("
	.byte	4
	.long	1183
	.ascii	"\200\200\210("
	.byte	4
	.long	1190
	.ascii	"\200\200\2000"
	.byte	4
	.long	1196
	.ascii	"\200\200\2040"
	.byte	4
	.long	1201
	.ascii	"\200\200\2100"
	.byte	4
	.long	1206
	.ascii	"\200\200\2140"
	.byte	4
	.long	1213
	.ascii	"\200\200\200P"
	.byte	4
	.long	1219
	.ascii	"\201\200\200P"
	.byte	4
	.long	1229
	.ascii	"\202\200\200P"
	.byte	4
	.long	1239
	.ascii	"\203\200\200P"
	.byte	4
	.long	1249
	.ascii	"\204\200\200P"
	.byte	4
	.long	1259
	.ascii	"\205\200\200P"
	.byte	4
	.long	1269
	.ascii	"\206\200\200P"
	.byte	4
	.long	1279
	.ascii	"\207\200\200P"
	.byte	4
	.long	1290
	.ascii	"\210\200\200P"
	.byte	4
	.long	1299
	.ascii	"\211\200\200P"
	.byte	4
	.long	1308
	.ascii	"\212\200\200P"
	.byte	4
	.long	1317
	.ascii	"\213\200\200P"
	.byte	4
	.long	1326
	.ascii	"\214\200\200P"
	.byte	4
	.long	1335
	.ascii	"\215\200\200P"
	.byte	4
	.long	1344
	.ascii	"\216\200\200P"
	.byte	4
	.long	1353
	.ascii	"\217\200\200P"
	.byte	4
	.long	1362
	.ascii	"\220\200\200P"
	.byte	4
	.long	1371
	.ascii	"\221\200\200P"
	.byte	4
	.long	1380
	.ascii	"\222\200\200P"
	.byte	4
	.long	1389
	.ascii	"\223\200\200P"
	.byte	8
	.long	1398
	.byte	8
	.byte	3
	.short	296
	.byte	4
	.byte	9
	.long	983
	.long	941
	.byte	4
	.byte	0
	.byte	9
	.long	1043
	.long	941
	.byte	4
	.byte	4
	.byte	0
	.byte	0
	.byte	9
	.long	1429
	.long	1251
	.byte	1
	.byte	176
	.byte	19
	.long	761
	.long	1433
	.byte	1
	.byte	3
	.byte	18
	.byte	1
	.byte	4
	.long	1447
	.byte	0
	.byte	4
	.long	1460
	.byte	1
	.byte	4
	.long	1466
	.byte	2
	.byte	4
	.long	1474
	.byte	3
	.byte	4
	.long	1482
	.byte	4
	.byte	4
	.long	1489
	.byte	5
	.byte	4
	.long	1498
	.byte	6
	.byte	4
	.long	1047
	.byte	7
	.byte	4
	.long	1504
	.byte	8
	.byte	4
	.long	1091
	.byte	9
	.byte	4
	.long	1512
	.byte	10
	.byte	4
	.long	1518
	.byte	11
	.byte	4
	.long	1524
	.byte	12
	.byte	4
	.long	1533
	.byte	13
	.byte	4
	.long	1543
	.byte	14
	.byte	4
	.long	1551
	.byte	15
	.byte	4
	.long	1558
	.byte	16
	.byte	4
	.long	1566
	.byte	17
	.byte	4
	.long	1576
	.byte	18
	.byte	4
	.long	1580
	.byte	19
	.byte	4
	.long	1592
	.byte	20
	.byte	4
	.long	1598
	.byte	21
	.byte	4
	.long	1603
	.byte	22
	.byte	4
	.long	1612
	.byte	23
	.byte	4
	.long	1137
	.byte	24
	.byte	4
	.long	1620
	.byte	25
	.byte	4
	.long	1625
	.byte	26
	.byte	4
	.long	1629
	.byte	27
	.byte	4
	.long	1634
	.byte	28
	.byte	4
	.long	1641
	.byte	29
	.byte	4
	.long	1645
	.byte	30
	.byte	4
	.long	1649
	.byte	31
	.byte	4
	.long	1653
	.byte	32
	.byte	4
	.long	1657
	.byte	33
	.byte	4
	.long	1661
	.byte	34
	.byte	4
	.long	1665
	.byte	35
	.byte	4
	.long	1670
	.byte	36
	.byte	4
	.long	1681
	.byte	37
	.byte	4
	.long	1686
	.byte	38
	.byte	4
	.long	1693
	.byte	39
	.byte	4
	.long	1700
	.byte	40
	.byte	4
	.long	1705
	.byte	41
	.byte	4
	.long	1712
	.byte	42
	.byte	4
	.long	1717
	.byte	43
	.byte	4
	.long	1724
	.byte	44
	.byte	4
	.long	1731
	.byte	45
	.byte	4
	.long	1738
	.byte	46
	.byte	4
	.long	1743
	.byte	47
	.byte	0
	.byte	0
	.byte	5
	.long	949
	.byte	5
	.byte	0
	.byte	16
	.long	961
	.byte	112
	.byte	4
	.byte	14
	.byte	8
	.byte	9
	.long	983
	.long	1593
	.byte	8
	.byte	0
	.byte	9
	.long	1043
	.long	1593
	.byte	8
	.byte	56
	.byte	0
	.byte	16
	.long	987
	.byte	56
	.byte	4
	.byte	1
	.byte	8
	.byte	9
	.long	1003
	.long	159
	.byte	8
	.byte	0
	.byte	9
	.long	1009
	.long	159
	.byte	8
	.byte	8
	.byte	9
	.long	1015
	.long	159
	.byte	8
	.byte	16
	.byte	9
	.long	1021
	.long	1658
	.byte	8
	.byte	24
	.byte	9
	.long	1037
	.long	1658
	.byte	8
	.byte	40
	.byte	0
	.byte	15
	.long	666
	.long	1025
	.byte	16
	.byte	5
	.long	1133
	.byte	7
	.byte	4
	.byte	2
	.long	1762
	.long	1690
	.byte	2
	.byte	12
	.long	1994
	.byte	3
	.long	1885
	.long	1766
	.byte	1
	.byte	3
	.short	806
	.byte	1
	.byte	4
	.long	944
	.byte	0
	.byte	4
	.long	1780
	.byte	1
	.byte	4
	.long	1784
	.byte	2
	.byte	4
	.long	1794
	.byte	3
	.byte	4
	.long	1803
	.byte	4
	.byte	4
	.long	1811
	.byte	5
	.byte	4
	.long	1821
	.byte	6
	.byte	4
	.long	1828
	.byte	7
	.byte	4
	.long	1834
	.byte	8
	.byte	4
	.long	1841
	.byte	9
	.byte	4
	.long	1846
	.byte	10
	.byte	4
	.long	1853
	.byte	11
	.byte	4
	.long	1860
	.byte	12
	.byte	4
	.long	1864
	.byte	13
	.byte	4
	.long	1125
	.byte	14
	.byte	4
	.long	1870
	.byte	15
	.byte	4
	.long	1882
	.byte	16
	.byte	4
	.long	1887
	.byte	17
	.byte	4
	.long	1898
	.byte	18
	.byte	4
	.long	1908
	.byte	19
	.byte	4
	.long	1917
	.byte	20
	.byte	4
	.long	1928
	.byte	21
	.byte	4
	.long	1936
	.byte	22
	.byte	4
	.long	1943
	.byte	23
	.byte	4
	.long	1951
	.byte	24
	.byte	4
	.long	1956
	.byte	25
	.byte	4
	.long	1964
	.byte	26
	.byte	4
	.long	1974
	.byte	27
	.byte	4
	.long	1979
	.byte	28
	.byte	4
	.long	1988
	.byte	29
	.byte	0
	.byte	5
	.long	1777
	.byte	7
	.byte	1
	.byte	2
	.long	2006
	.long	1907
	.byte	2
	.byte	137
	.long	2079
	.byte	3
	.long	1976
	.long	2020
	.byte	1
	.byte	3
	.short	1047
	.byte	1
	.byte	4
	.long	2043
	.byte	0
	.byte	4
	.long	2045
	.byte	1
	.byte	4
	.long	2050
	.byte	2
	.byte	4
	.long	2054
	.byte	3
	.byte	4
	.long	2058
	.byte	4
	.byte	4
	.long	1512
	.byte	5
	.byte	4
	.long	2064
	.byte	6
	.byte	4
	.long	2068
	.byte	7
	.byte	4
	.long	2074
	.byte	8
	.byte	0
	.byte	5
	.long	2040
	.byte	7
	.byte	1
	.byte	2
	.long	2101
	.long	1998
	.byte	2
	.byte	129
	.long	2171
	.byte	20
	.long	2108
	.short	512
	.byte	3
	.byte	1
	.byte	8
	.byte	9
	.long	261
	.long	188
	.byte	8
	.byte	0
	.byte	9
	.long	894
	.long	783
	.byte	8
	.byte	64
	.byte	9
	.long	1762
	.long	1690
	.byte	1
	.byte	248
	.byte	9
	.long	2115
	.long	1907
	.byte	1
	.byte	249
	.byte	9
	.long	2120
	.long	2064
	.byte	1
	.byte	250
	.byte	0
	.byte	21
	.long	2135
	.short	256
	.byte	3
	.short	2405
	.byte	1
	.byte	9
	.long	2156
	.long	2098
	.byte	1
	.byte	0
	.byte	9
	.long	358
	.long	705
	.byte	1
	.byte	255
	.byte	0
	.byte	10
	.long	705
	.long	2163
	.byte	11
	.long	166
	.byte	255
	.byte	0
	.byte	2
	.long	2043
	.long	2129
	.byte	1
	.byte	167
	.long	5097
	.byte	16
	.long	2186
	.byte	32
	.byte	1
	.byte	162
	.byte	8
	.byte	9
	.long	2209
	.long	3584
	.byte	8
	.byte	0
	.byte	8
	.long	2284
	.byte	16
	.byte	1
	.short	397
	.byte	8
	.byte	9
	.long	2321
	.long	4704
	.byte	8
	.byte	0
	.byte	0
	.byte	8
	.long	2492
	.byte	24
	.byte	1
	.short	405
	.byte	8
	.byte	9
	.long	2321
	.long	4704
	.byte	8
	.byte	0
	.byte	9
	.long	2533
	.long	90
	.byte	1
	.byte	16
	.byte	0
	.byte	8
	.long	2906
	.byte	24
	.byte	1
	.short	432
	.byte	8
	.byte	9
	.long	2321
	.long	4704
	.byte	8
	.byte	0
	.byte	9
	.long	2949
	.long	2236
	.byte	1
	.byte	16
	.byte	3
	.long	4741
	.long	2954
	.byte	1
	.byte	1
	.short	439
	.byte	1
	.byte	4
	.long	3014
	.byte	0
	.byte	4
	.long	3022
	.byte	1
	.byte	4
	.long	3026
	.byte	2
	.byte	4
	.long	3030
	.byte	3
	.byte	4
	.long	3034
	.byte	4
	.byte	4
	.long	3040
	.byte	5
	.byte	0
	.byte	0
	.byte	8
	.long	3085
	.byte	24
	.byte	1
	.short	469
	.byte	8
	.byte	9
	.long	2321
	.long	4704
	.byte	8
	.byte	0
	.byte	9
	.long	3129
	.long	2320
	.byte	1
	.byte	16
	.byte	3
	.long	1976
	.long	3134
	.byte	1
	.byte	1
	.short	476
	.byte	1
	.byte	4
	.long	3192
	.byte	0
	.byte	4
	.long	3196
	.byte	1
	.byte	4
	.long	3200
	.byte	2
	.byte	4
	.long	3204
	.byte	3
	.byte	4
	.long	3208
	.byte	4
	.byte	4
	.long	3212
	.byte	5
	.byte	4
	.long	3216
	.byte	6
	.byte	4
	.long	3220
	.byte	7
	.byte	4
	.long	3224
	.byte	8
	.byte	0
	.byte	0
	.byte	8
	.long	3298
	.byte	24
	.byte	1
	.short	490
	.byte	8
	.byte	9
	.long	2321
	.long	4704
	.byte	8
	.byte	0
	.byte	9
	.long	3129
	.long	2422
	.byte	1
	.byte	16
	.byte	3
	.long	90
	.long	3343
	.byte	1
	.byte	1
	.short	497
	.byte	1
	.byte	4
	.long	3402
	.byte	0
	.byte	4
	.long	3413
	.byte	1
	.byte	0
	.byte	0
	.byte	8
	.long	3644
	.byte	24
	.byte	1
	.short	416
	.byte	8
	.byte	9
	.long	2321
	.long	4704
	.byte	8
	.byte	0
	.byte	9
	.long	2949
	.long	2482
	.byte	1
	.byte	16
	.byte	3
	.long	90
	.long	3687
	.byte	1
	.byte	1
	.short	423
	.byte	1
	.byte	4
	.long	3744
	.byte	0
	.byte	4
	.long	3751
	.byte	1
	.byte	4
	.long	3758
	.byte	2
	.byte	4
	.long	3764
	.byte	3
	.byte	0
	.byte	0
	.byte	8
	.long	4051
	.byte	24
	.byte	1
	.short	450
	.byte	8
	.byte	9
	.long	2321
	.long	4704
	.byte	8
	.byte	0
	.byte	9
	.long	2949
	.long	2554
	.byte	1
	.byte	16
	.byte	3
	.long	90
	.long	4101
	.byte	1
	.byte	1
	.short	456
	.byte	1
	.byte	4
	.long	4165
	.byte	0
	.byte	4
	.long	4170
	.byte	1
	.byte	4
	.long	4178
	.byte	2
	.byte	4
	.long	4183
	.byte	3
	.byte	0
	.byte	0
	.byte	8
	.long	4304
	.byte	24
	.byte	1
	.short	504
	.byte	8
	.byte	9
	.long	2321
	.long	4704
	.byte	8
	.byte	0
	.byte	9
	.long	4346
	.long	2626
	.byte	1
	.byte	16
	.byte	3
	.long	4741
	.long	4351
	.byte	1
	.byte	1
	.short	510
	.byte	1
	.byte	4
	.long	4406
	.byte	0
	.byte	4
	.long	4412
	.byte	1
	.byte	4
	.long	4417
	.byte	2
	.byte	4
	.long	4422
	.byte	3
	.byte	0
	.byte	0
	.byte	8
	.long	4587
	.byte	12
	.byte	1
	.short	522
	.byte	4
	.byte	9
	.long	4629
	.long	1668
	.byte	4
	.byte	0
	.byte	9
	.long	4631
	.long	1668
	.byte	4
	.byte	4
	.byte	9
	.long	4633
	.long	1668
	.byte	4
	.byte	8
	.byte	0
	.byte	8
	.long	4650
	.byte	2
	.byte	1
	.short	528
	.byte	1
	.byte	9
	.long	4694
	.long	4748
	.byte	1
	.byte	0
	.byte	9
	.long	4722
	.long	2742
	.byte	1
	.byte	1
	.byte	3
	.long	90
	.long	4739
	.byte	1
	.byte	1
	.short	529
	.byte	1
	.byte	4
	.long	944
	.byte	0
	.byte	4
	.long	4799
	.byte	1
	.byte	4
	.long	4807
	.byte	2
	.byte	4
	.long	4812
	.byte	3
	.byte	0
	.byte	0
	.byte	8
	.long	4844
	.byte	24
	.byte	1
	.short	540
	.byte	4
	.byte	9
	.long	4884
	.long	1668
	.byte	4
	.byte	0
	.byte	9
	.long	4899
	.long	1668
	.byte	4
	.byte	4
	.byte	9
	.long	4629
	.long	1668
	.byte	4
	.byte	8
	.byte	9
	.long	4631
	.long	1668
	.byte	4
	.byte	12
	.byte	9
	.long	4633
	.long	1668
	.byte	4
	.byte	16
	.byte	9
	.long	4912
	.long	2858
	.byte	1
	.byte	20
	.byte	3
	.long	90
	.long	4925
	.byte	1
	.byte	1
	.short	541
	.byte	1
	.byte	4
	.long	4977
	.byte	0
	.byte	4
	.long	4991
	.byte	1
	.byte	4
	.long	5004
	.byte	2
	.byte	0
	.byte	0
	.byte	9
	.long	1429
	.long	2903
	.byte	1
	.byte	24
	.byte	19
	.long	705
	.long	5043
	.byte	1
	.byte	1
	.byte	162
	.byte	1
	.byte	4
	.long	2248
	.byte	0
	.byte	4
	.long	2253
	.byte	1
	.byte	4
	.long	2259
	.byte	2
	.byte	4
	.long	2265
	.byte	3
	.byte	4
	.long	2272
	.byte	4
	.byte	4
	.long	2360
	.byte	5
	.byte	4
	.long	2371
	.byte	6
	.byte	4
	.long	2382
	.byte	7
	.byte	4
	.long	2405
	.byte	8
	.byte	4
	.long	2427
	.byte	9
	.byte	4
	.long	2445
	.byte	10
	.byte	4
	.long	2462
	.byte	11
	.byte	4
	.long	2483
	.byte	12
	.byte	4
	.long	2549
	.byte	13
	.byte	4
	.long	2557
	.byte	14
	.byte	4
	.long	2567
	.byte	15
	.byte	4
	.long	2579
	.byte	16
	.byte	4
	.long	2592
	.byte	17
	.byte	4
	.long	2605
	.byte	18
	.byte	4
	.long	2624
	.byte	19
	.byte	4
	.long	2639
	.byte	20
	.byte	4
	.long	2658
	.byte	21
	.byte	4
	.long	2673
	.byte	22
	.byte	4
	.long	2687
	.byte	23
	.byte	4
	.long	2700
	.byte	24
	.byte	4
	.long	2715
	.byte	25
	.byte	4
	.long	2734
	.byte	26
	.byte	4
	.long	2751
	.byte	27
	.byte	4
	.long	2765
	.byte	28
	.byte	4
	.long	2786
	.byte	29
	.byte	4
	.long	2804
	.byte	30
	.byte	4
	.long	2818
	.byte	31
	.byte	4
	.long	2836
	.byte	32
	.byte	4
	.long	2858
	.byte	33
	.byte	4
	.long	2868
	.byte	34
	.byte	4
	.long	2878
	.byte	35
	.byte	4
	.long	2892
	.byte	36
	.byte	4
	.long	3046
	.byte	37
	.byte	4
	.long	3057
	.byte	38
	.byte	4
	.long	3068
	.byte	39
	.byte	4
	.long	3228
	.byte	40
	.byte	4
	.long	3237
	.byte	41
	.byte	4
	.long	3252
	.byte	42
	.byte	4
	.long	3265
	.byte	43
	.byte	4
	.long	3280
	.byte	44
	.byte	4
	.long	3421
	.byte	45
	.byte	4
	.long	3435
	.byte	46
	.byte	4
	.long	3451
	.byte	47
	.byte	4
	.long	3469
	.byte	48
	.byte	4
	.long	3482
	.byte	49
	.byte	4
	.long	3493
	.byte	50
	.byte	4
	.long	3507
	.byte	51
	.byte	4
	.long	3529
	.byte	52
	.byte	4
	.long	3546
	.byte	53
	.byte	4
	.long	3559
	.byte	54
	.byte	4
	.long	3580
	.byte	55
	.byte	4
	.long	3592
	.byte	56
	.byte	4
	.long	3612
	.byte	57
	.byte	4
	.long	3621
	.byte	58
	.byte	4
	.long	3630
	.byte	59
	.byte	4
	.long	3769
	.byte	60
	.byte	4
	.long	3777
	.byte	61
	.byte	4
	.long	3789
	.byte	62
	.byte	4
	.long	3800
	.byte	63
	.byte	4
	.long	3814
	.byte	64
	.byte	4
	.long	3822
	.byte	65
	.byte	4
	.long	3832
	.byte	66
	.byte	4
	.long	3847
	.byte	67
	.byte	4
	.long	3860
	.byte	68
	.byte	4
	.long	3877
	.byte	69
	.byte	4
	.long	3886
	.byte	70
	.byte	4
	.long	3897
	.byte	71
	.byte	4
	.long	3906
	.byte	72
	.byte	4
	.long	3916
	.byte	73
	.byte	4
	.long	3927
	.byte	74
	.byte	4
	.long	3944
	.byte	75
	.byte	4
	.long	3962
	.byte	76
	.byte	4
	.long	3972
	.byte	77
	.byte	4
	.long	3981
	.byte	78
	.byte	4
	.long	3990
	.byte	79
	.byte	4
	.long	4005
	.byte	80
	.byte	4
	.long	4015
	.byte	81
	.byte	4
	.long	4030
	.byte	82
	.byte	4
	.long	4194
	.byte	83
	.byte	4
	.long	4206
	.byte	84
	.byte	4
	.long	4223
	.byte	85
	.byte	4
	.long	4233
	.byte	86
	.byte	4
	.long	4248
	.byte	87
	.byte	4
	.long	4259
	.byte	88
	.byte	4
	.long	4273
	.byte	89
	.byte	4
	.long	4280
	.byte	90
	.byte	4
	.long	4291
	.byte	91
	.byte	4
	.long	4427
	.byte	92
	.byte	4
	.long	4435
	.byte	93
	.byte	4
	.long	4445
	.byte	94
	.byte	4
	.long	4455
	.byte	95
	.byte	4
	.long	4468
	.byte	96
	.byte	4
	.long	4484
	.byte	97
	.byte	4
	.long	4498
	.byte	98
	.byte	4
	.long	4512
	.byte	99
	.byte	4
	.long	4522
	.byte	100
	.byte	4
	.long	4535
	.byte	101
	.byte	4
	.long	4548
	.byte	102
	.byte	4
	.long	4561
	.byte	103
	.byte	4
	.long	4574
	.byte	104
	.byte	4
	.long	4635
	.byte	105
	.byte	4
	.long	4822
	.byte	106
	.byte	4
	.long	4833
	.byte	107
	.byte	4
	.long	5021
	.byte	108
	.byte	4
	.long	5030
	.byte	109
	.byte	4
	.long	788
	.byte	110
	.byte	0
	.byte	0
	.byte	22
	.long	2217
	.byte	24
	.byte	1
	.byte	162
	.byte	8
	.byte	18
	.long	2248
	.long	1554
	.byte	0
	.byte	18
	.long	2253
	.long	1554
	.byte	0
	.byte	18
	.long	2259
	.long	1554
	.byte	0
	.byte	18
	.long	2265
	.long	1554
	.byte	0
	.byte	18
	.long	2272
	.long	2149
	.byte	0
	.byte	18
	.long	2360
	.long	2149
	.byte	0
	.byte	18
	.long	2371
	.long	2149
	.byte	0
	.byte	18
	.long	2382
	.long	2149
	.byte	0
	.byte	18
	.long	2405
	.long	2149
	.byte	0
	.byte	18
	.long	2427
	.long	2149
	.byte	0
	.byte	18
	.long	2445
	.long	2149
	.byte	0
	.byte	18
	.long	2462
	.long	2149
	.byte	0
	.byte	18
	.long	2483
	.long	2171
	.byte	0
	.byte	18
	.long	2549
	.long	2171
	.byte	0
	.byte	18
	.long	2557
	.long	2171
	.byte	0
	.byte	18
	.long	2567
	.long	2171
	.byte	0
	.byte	18
	.long	2579
	.long	2149
	.byte	0
	.byte	18
	.long	2592
	.long	2149
	.byte	0
	.byte	18
	.long	2605
	.long	2149
	.byte	0
	.byte	18
	.long	2624
	.long	2149
	.byte	0
	.byte	18
	.long	2639
	.long	2149
	.byte	0
	.byte	18
	.long	2658
	.long	2149
	.byte	0
	.byte	18
	.long	2673
	.long	2149
	.byte	0
	.byte	18
	.long	2687
	.long	2149
	.byte	0
	.byte	18
	.long	2700
	.long	2149
	.byte	0
	.byte	18
	.long	2715
	.long	2149
	.byte	0
	.byte	18
	.long	2734
	.long	2149
	.byte	0
	.byte	18
	.long	2751
	.long	2149
	.byte	0
	.byte	18
	.long	2765
	.long	2149
	.byte	0
	.byte	18
	.long	2786
	.long	2149
	.byte	0
	.byte	18
	.long	2804
	.long	2149
	.byte	0
	.byte	18
	.long	2818
	.long	2149
	.byte	0
	.byte	18
	.long	2836
	.long	2149
	.byte	0
	.byte	18
	.long	2858
	.long	2149
	.byte	0
	.byte	18
	.long	2868
	.long	2149
	.byte	0
	.byte	18
	.long	2878
	.long	2149
	.byte	0
	.byte	18
	.long	2892
	.long	2204
	.byte	0
	.byte	18
	.long	3046
	.long	2149
	.byte	0
	.byte	18
	.long	3057
	.long	2149
	.byte	0
	.byte	18
	.long	3068
	.long	2288
	.byte	0
	.byte	18
	.long	3228
	.long	2149
	.byte	0
	.byte	18
	.long	3237
	.long	2288
	.byte	0
	.byte	18
	.long	3252
	.long	2149
	.byte	0
	.byte	18
	.long	3265
	.long	2149
	.byte	0
	.byte	18
	.long	3280
	.long	2390
	.byte	0
	.byte	18
	.long	3421
	.long	2149
	.byte	0
	.byte	18
	.long	3435
	.long	2149
	.byte	0
	.byte	18
	.long	3451
	.long	2390
	.byte	0
	.byte	18
	.long	3469
	.long	2149
	.byte	0
	.byte	18
	.long	3482
	.long	2149
	.byte	0
	.byte	18
	.long	3493
	.long	2149
	.byte	0
	.byte	18
	.long	3507
	.long	2149
	.byte	0
	.byte	18
	.long	3529
	.long	2149
	.byte	0
	.byte	18
	.long	3546
	.long	2149
	.byte	0
	.byte	18
	.long	3559
	.long	2149
	.byte	0
	.byte	18
	.long	3580
	.long	2149
	.byte	0
	.byte	18
	.long	3592
	.long	2149
	.byte	0
	.byte	18
	.long	3612
	.long	2149
	.byte	0
	.byte	18
	.long	3621
	.long	2149
	.byte	0
	.byte	18
	.long	3630
	.long	2450
	.byte	0
	.byte	18
	.long	3769
	.long	1554
	.byte	0
	.byte	18
	.long	3777
	.long	1554
	.byte	0
	.byte	18
	.long	3789
	.long	1554
	.byte	0
	.byte	18
	.long	3800
	.long	1554
	.byte	0
	.byte	18
	.long	3814
	.long	2149
	.byte	0
	.byte	18
	.long	3822
	.long	2149
	.byte	0
	.byte	18
	.long	3832
	.long	2149
	.byte	0
	.byte	18
	.long	3847
	.long	2149
	.byte	0
	.byte	18
	.long	3860
	.long	2149
	.byte	0
	.byte	18
	.long	3877
	.long	2149
	.byte	0
	.byte	18
	.long	3886
	.long	2149
	.byte	0
	.byte	18
	.long	3897
	.long	2149
	.byte	0
	.byte	18
	.long	3906
	.long	2149
	.byte	0
	.byte	18
	.long	3916
	.long	2149
	.byte	0
	.byte	18
	.long	3927
	.long	2149
	.byte	0
	.byte	18
	.long	3944
	.long	2149
	.byte	0
	.byte	18
	.long	3962
	.long	2149
	.byte	0
	.byte	18
	.long	3972
	.long	2149
	.byte	0
	.byte	18
	.long	3981
	.long	2149
	.byte	0
	.byte	18
	.long	3990
	.long	2149
	.byte	0
	.byte	18
	.long	4005
	.long	2149
	.byte	0
	.byte	18
	.long	4015
	.long	2149
	.byte	0
	.byte	18
	.long	4030
	.long	2522
	.byte	0
	.byte	18
	.long	4194
	.long	2149
	.byte	0
	.byte	18
	.long	4206
	.long	2149
	.byte	0
	.byte	18
	.long	4223
	.long	2149
	.byte	0
	.byte	18
	.long	4233
	.long	2149
	.byte	0
	.byte	18
	.long	4248
	.long	2149
	.byte	0
	.byte	18
	.long	4259
	.long	2149
	.byte	0
	.byte	18
	.long	4273
	.long	2149
	.byte	0
	.byte	18
	.long	4280
	.long	2149
	.byte	0
	.byte	18
	.long	4291
	.long	2594
	.byte	0
	.byte	18
	.long	4427
	.long	2149
	.byte	0
	.byte	18
	.long	4435
	.long	2149
	.byte	0
	.byte	18
	.long	4445
	.long	2149
	.byte	0
	.byte	18
	.long	4455
	.long	2149
	.byte	0
	.byte	18
	.long	4468
	.long	2149
	.byte	0
	.byte	18
	.long	4484
	.long	2149
	.byte	0
	.byte	18
	.long	4498
	.long	1554
	.byte	0
	.byte	18
	.long	4512
	.long	2149
	.byte	0
	.byte	18
	.long	4522
	.long	1554
	.byte	0
	.byte	18
	.long	4535
	.long	1554
	.byte	0
	.byte	18
	.long	4548
	.long	1554
	.byte	0
	.byte	18
	.long	4561
	.long	1554
	.byte	0
	.byte	18
	.long	4574
	.long	2666
	.byte	0
	.byte	18
	.long	4635
	.long	2710
	.byte	0
	.byte	18
	.long	4822
	.long	2666
	.byte	0
	.byte	18
	.long	4833
	.long	2782
	.byte	0
	.byte	18
	.long	5021
	.long	1554
	.byte	0
	.byte	18
	.long	5030
	.long	1554
	.byte	0
	.byte	18
	.long	788
	.long	1554
	.byte	0
	.byte	0
	.byte	14
	.long	2346
	.byte	16
	.byte	8
	.byte	9
	.long	2209
	.long	4734
	.byte	8
	.byte	0
	.byte	9
	.long	2355
	.long	705
	.byte	1
	.byte	8
	.byte	0
	.byte	5
	.long	2351
	.byte	7
	.byte	8
	.byte	5
	.long	3011
	.byte	7
	.byte	1
	.byte	5
	.long	4717
	.byte	2
	.byte	1
	.byte	23
	.long	5122
	.long	1668
	.byte	5
	.byte	3
	.byte	9
	.byte	3
	.quad	_hoist.counter
	.long	5130
	.byte	6
	.long	944
	.long	2064
	.byte	3
	.short	2415
	.long	5144
	.byte	6
	.long	5170
	.long	209
	.byte	6
	.short	2671
	.long	5179
	.byte	24
	.long	5207
	.long	5222
	.byte	5
	.byte	29

	.byte	1
	.byte	25
	.quad	Lfunc_begin0
Lset138 = Lfunc_end0-Lfunc_begin0
	.long	Lset138
	.byte	1
	.byte	109
	.long	5239
	.long	5231
	.byte	5
	.byte	33
	.long	4734

	.byte	26
Lset139 = Ldebug_loc0-Lsection_debug_loc
	.long	Lset139
	.long	5401
	.byte	5
	.byte	33
	.long	5287
	.byte	27
Lset140 = Ldebug_loc1-Lsection_debug_loc
	.long	Lset140
	.long	5439
	.byte	5
	.byte	34
	.long	1668
	.byte	27
Lset141 = Ldebug_loc2-Lsection_debug_loc
	.long	Lset141
	.long	5441
	.byte	5
	.byte	34
	.long	4734
	.byte	27
Lset142 = Ldebug_loc3-Lsection_debug_loc
	.long	Lset142
	.long	5443
	.byte	5
	.byte	34
	.long	159
	.byte	28
	.long	4812
Lset143 = Ldebug_ranges0-Ldebug_range
	.long	Lset143
	.byte	5
	.byte	35
	.byte	36
	.byte	0
	.byte	29
	.quad	Lfunc_begin1
Lset144 = Lfunc_end1-Lfunc_begin1
	.long	Lset144
	.byte	1
	.byte	109
	.long	5259
	.long	5253
	.byte	5
	.byte	28
	.long	1668

	.byte	25
	.quad	Lfunc_begin2
Lset145 = Lfunc_end2-Lfunc_begin2
	.long	Lset145
	.byte	1
	.byte	109
	.long	5279
	.long	5271
	.byte	5
	.byte	23
	.long	4734

	.byte	26
Lset146 = Ldebug_loc4-Lsection_debug_loc
	.long	Lset146
	.long	5401
	.byte	5
	.byte	23
	.long	5287
	.byte	27
Lset147 = Ldebug_loc5-Lsection_debug_loc
	.long	Lset147
	.long	5441
	.byte	5
	.byte	24
	.long	4734
	.byte	27
Lset148 = Ldebug_loc6-Lsection_debug_loc
	.long	Lset148
	.long	5443
	.byte	5
	.byte	24
	.long	159
	.byte	0
	.byte	24
	.long	5293
	.long	5309
	.byte	5
	.byte	9

	.byte	1
	.byte	25
	.quad	Lfunc_begin3
Lset149 = Lfunc_end3-Lfunc_begin3
	.long	Lset149
	.byte	1
	.byte	109
	.long	5328
	.long	5319
	.byte	5
	.byte	18
	.long	4734

	.byte	26
Lset150 = Ldebug_loc7-Lsection_debug_loc
	.long	Lset150
	.long	5401
	.byte	5
	.byte	18
	.long	5287
	.byte	27
Lset151 = Ldebug_loc8-Lsection_debug_loc
	.long	Lset151
	.long	5439
	.byte	5
	.byte	19
	.long	1668
	.byte	27
Lset152 = Ldebug_loc9-Lsection_debug_loc
	.long	Lset152
	.long	5441
	.byte	5
	.byte	19
	.long	4734
	.byte	27
Lset153 = Ldebug_loc10-Lsection_debug_loc
	.long	Lset153
	.long	5443
	.byte	5
	.byte	19
	.long	159
	.byte	28
	.long	5030
Lset154 = Ldebug_ranges1-Ldebug_range
	.long	Lset154
	.byte	5
	.byte	20
	.byte	37
	.byte	0
	.byte	29
	.quad	Lfunc_begin4
Lset155 = Lfunc_end4-Lfunc_begin4
	.long	Lset155
	.byte	1
	.byte	109
	.long	5348
	.long	5343
	.byte	5
	.byte	4
	.long	1554

	.byte	24
	.long	5359
	.long	5373
	.byte	5
	.byte	5

	.byte	1
	.byte	25
	.quad	Lfunc_begin5
Lset156 = Lfunc_end5-Lfunc_begin5
	.long	Lset156
	.byte	1
	.byte	109
	.long	5388
	.long	5381
	.byte	5
	.byte	13
	.long	4734

	.byte	26
Lset157 = Ldebug_loc11-Lsection_debug_loc
	.long	Lset157
	.long	5401
	.byte	5
	.byte	13
	.long	5287
	.byte	27
Lset158 = Ldebug_loc12-Lsection_debug_loc
	.long	Lset158
	.long	5439
	.byte	5
	.byte	14
	.long	1668
	.byte	27
Lset159 = Ldebug_loc13-Lsection_debug_loc
	.long	Lset159
	.long	5441
	.byte	5
	.byte	14
	.long	4734
	.byte	27
Lset160 = Ldebug_loc14-Lsection_debug_loc
	.long	Lset160
	.long	5443
	.byte	5
	.byte	14
	.long	159
	.byte	28
	.long	5173
Lset161 = Ldebug_ranges2-Ldebug_range
	.long	Lset161
	.byte	5
	.byte	15
	.byte	35
	.byte	0
	.byte	13
	.long	5296
	.long	5403
	.byte	16
	.long	5418
	.byte	16
	.byte	5
	.byte	2
	.byte	8
	.byte	9
	.long	339
	.long	5328
	.byte	8
	.byte	0
	.byte	9
	.long	358
	.long	159
	.byte	8
	.byte	8
	.byte	0
	.byte	13
	.long	4734
	.long	5426
	.byte	0
Ldebug_info_end0:
	.section	__DWARF,__debug_ranges,regular,debug
Ldebug_range:
Ldebug_ranges0:
Lset162 = Ltmp2-Lfunc_begin0
	.quad	Lset162
Lset163 = Ltmp4-Lfunc_begin0
	.quad	Lset163
Lset164 = Ltmp8-Lfunc_begin0
	.quad	Lset164
Lset165 = Ltmp11-Lfunc_begin0
	.quad	Lset165
	.quad	0
	.quad	0
Ldebug_ranges1:
Lset166 = Ltmp45-Lfunc_begin0
	.quad	Lset166
Lset167 = Ltmp47-Lfunc_begin0
	.quad	Lset167
Lset168 = Ltmp50-Lfunc_begin0
	.quad	Lset168
Lset169 = Ltmp51-Lfunc_begin0
	.quad	Lset169
	.quad	0
	.quad	0
Ldebug_ranges2:
Lset170 = Ltmp64-Lfunc_begin0
	.quad	Lset170
Lset171 = Ltmp66-Lfunc_begin0
	.quad	Lset171
Lset172 = Ltmp69-Lfunc_begin0
	.quad	Lset172
Lset173 = Ltmp70-Lfunc_begin0
	.quad	Lset173
	.quad	0
	.quad	0
	.section	__DWARF,__debug_str,regular,debug
Linfo_string:
	.asciz	"zig 0.17.0"
	.asciz	"hoist"
	.asciz	"/Users/shreeve/Data/Code/claude/rig/rig/sched-check-study/micro"
	.asciz	"output_mode"
	.asciz	"lang.OutputMode"
	.asciz	"u2"
	.asciz	"Exe"
	.asciz	"Lib"
	.asciz	"Obj"
	.asciz	"builtin.output_mode"
	.asciz	"empty"
	.asciz	"Target.Cpu.Feature"
	.asciz	"Target.Cpu.Feature.Set"
	.asciz	"ints"
	.asciz	"[6]usize"
	.asciz	"usize"
	.asciz	"__ARRAY_SIZE_TYPE__"
	.asciz	"Target.Cpu.Feature.Set.empty"
	.asciz	"cpu"
	.asciz	"Target.Cpu"
	.asciz	"model"
	.asciz	"*const Target.Cpu.Model"
	.asciz	"Target.Cpu.Model"
	.asciz	"name"
	.asciz	"[]const u8"
	.asciz	"ptr"
	.asciz	"[*]const u8"
	.asciz	"u8"
	.asciz	"len"
	.asciz	"llvm_name"
	.asciz	"?[:0]const u8"
	.asciz	"[:0]const u8"
	.asciz	"[*:0]const u8"
	.asciz	"features"
	.asciz	"arch"
	.asciz	"Target.Cpu.Arch"
	.asciz	"u6"
	.asciz	"aarch64"
	.asciz	"aarch64_be"
	.asciz	"alpha"
	.asciz	"amdgcn"
	.asciz	"arc"
	.asciz	"arceb"
	.asciz	"arm"
	.asciz	"armeb"
	.asciz	"avr"
	.asciz	"bpfeb"
	.asciz	"bpfel"
	.asciz	"csky"
	.asciz	"ez80"
	.asciz	"hexagon"
	.asciz	"hppa"
	.asciz	"hppa64"
	.asciz	"kalimba"
	.asciz	"kvx"
	.asciz	"lanai"
	.asciz	"loongarch32"
	.asciz	"loongarch64"
	.asciz	"m68k"
	.asciz	"m88k"
	.asciz	"microblaze"
	.asciz	"microblazeel"
	.asciz	"mips"
	.asciz	"mipsel"
	.asciz	"mips64"
	.asciz	"mips64el"
	.asciz	"msp430"
	.asciz	"nvptx"
	.asciz	"nvptx64"
	.asciz	"or1k"
	.asciz	"powerpc"
	.asciz	"powerpcle"
	.asciz	"powerpc64"
	.asciz	"powerpc64le"
	.asciz	"propeller"
	.asciz	"riscv32"
	.asciz	"riscv32be"
	.asciz	"riscv64"
	.asciz	"riscv64be"
	.asciz	"s390x"
	.asciz	"sh"
	.asciz	"sheb"
	.asciz	"sparc"
	.asciz	"sparc64"
	.asciz	"spork8"
	.asciz	"spirv32"
	.asciz	"spirv64"
	.asciz	"thumb"
	.asciz	"thumbeb"
	.asciz	"ve"
	.asciz	"wasm32"
	.asciz	"wasm64"
	.asciz	"x86_16"
	.asciz	"x86"
	.asciz	"x86_64"
	.asciz	"xcore"
	.asciz	"xtensa"
	.asciz	"xtensaeb"
	.asciz	"builtin.cpu"
	.asciz	"os"
	.asciz	"Target.Os"
	.asciz	"version_range"
	.asciz	"Target.Os.VersionRange"
	.asciz	"none"
	.asciz	"void"
	.asciz	"semver"
	.asciz	"SemanticVersion.Range"
	.asciz	"min"
	.asciz	"SemanticVersion"
	.asciz	"major"
	.asciz	"minor"
	.asciz	"patch"
	.asciz	"pre"
	.asciz	"?[]const u8"
	.asciz	"build"
	.asciz	"max"
	.asciz	"hurd"
	.asciz	"Target.Os.HurdVersionRange"
	.asciz	"range"
	.asciz	"glibc"
	.asciz	"linux"
	.asciz	"Target.Os.LinuxVersionRange"
	.asciz	"android"
	.asciz	"u32"
	.asciz	"windows"
	.asciz	"Target.Os.WindowsVersion"
	.asciz	"nt4"
	.asciz	"win2k"
	.asciz	"xp"
	.asciz	"ws2003"
	.asciz	"vista"
	.asciz	"win7"
	.asciz	"win8"
	.asciz	"win8_1"
	.asciz	"win10"
	.asciz	"win10_th2"
	.asciz	"win10_rs1"
	.asciz	"win10_rs2"
	.asciz	"win10_rs3"
	.asciz	"win10_rs4"
	.asciz	"win10_rs5"
	.asciz	"win10_19h1"
	.asciz	"win10_vb"
	.asciz	"win10_mn"
	.asciz	"win10_fe"
	.asciz	"win10_co"
	.asciz	"win10_ni"
	.asciz	"win10_cu"
	.asciz	"win11_zn"
	.asciz	"win11_ga"
	.asciz	"win11_ge"
	.asciz	"win11_dt"
	.asciz	"win11_br"
	.asciz	"win11_kr"
	.asciz	"Target.Os.WindowsVersion.Range"
	.asciz	"tag"
	.asciz	"Target.Os.Tag"
	.asciz	"freestanding"
	.asciz	"other"
	.asciz	"contiki"
	.asciz	"fuchsia"
	.asciz	"hermit"
	.asciz	"managarm"
	.asciz	"haiku"
	.asciz	"illumos"
	.asciz	"plan9"
	.asciz	"rtems"
	.asciz	"serenity"
	.asciz	"dragonfly"
	.asciz	"freebsd"
	.asciz	"netbsd"
	.asciz	"openbsd"
	.asciz	"driverkit"
	.asciz	"ios"
	.asciz	"maccatalyst"
	.asciz	"macos"
	.asciz	"tvos"
	.asciz	"visionos"
	.asciz	"watchos"
	.asciz	"uefi"
	.asciz	"3ds"
	.asciz	"wiiu"
	.asciz	"switch"
	.asciz	"gba"
	.asciz	"psx"
	.asciz	"ps3"
	.asciz	"ps4"
	.asciz	"ps5"
	.asciz	"psp"
	.asciz	"vita"
	.asciz	"emscripten"
	.asciz	"wasi"
	.asciz	"amdhsa"
	.asciz	"amdpal"
	.asciz	"cuda"
	.asciz	"mesa3d"
	.asciz	"nvcl"
	.asciz	"opencl"
	.asciz	"opengl"
	.asciz	"vulkan"
	.asciz	"tios"
	.asciz	"ashetos"
	.asciz	"builtin.os"
	.asciz	"abi"
	.asciz	"Target.Abi"
	.asciz	"u5"
	.asciz	"gnu"
	.asciz	"gnuabin32"
	.asciz	"gnuabi64"
	.asciz	"gnueabi"
	.asciz	"gnueabihf"
	.asciz	"gnuf32"
	.asciz	"gnusf"
	.asciz	"gnux32"
	.asciz	"eabi"
	.asciz	"eabihf"
	.asciz	"abin32"
	.asciz	"x32"
	.asciz	"ilp32"
	.asciz	"androideabi"
	.asciz	"musl"
	.asciz	"muslabin32"
	.asciz	"muslabi64"
	.asciz	"musleabi"
	.asciz	"musleabihf"
	.asciz	"muslf32"
	.asciz	"muslsf"
	.asciz	"muslx32"
	.asciz	"msvc"
	.asciz	"itanium"
	.asciz	"simulator"
	.asciz	"ohos"
	.asciz	"ohoseabi"
	.asciz	"call0"
	.asciz	"builtin.abi"
	.asciz	"object_format"
	.asciz	"Target.ObjectFormat"
	.asciz	"u4"
	.asciz	"c"
	.asciz	"coff"
	.asciz	"elf"
	.asciz	"hex"
	.asciz	"macho"
	.asciz	"raw"
	.asciz	"spirv"
	.asciz	"wasm"
	.asciz	"builtin.object_format"
	.asciz	"target"
	.asciz	"Target"
	.asciz	"ofmt"
	.asciz	"dynamic_linker"
	.asciz	"Target.DynamicLinker"
	.asciz	"buffer"
	.asciz	"[255]u8"
	.asciz	"builtin.target"
	.asciz	"lang.CallingConvention"
	.asciz	"payload"
	.asciz	"lang.CallingConvention:Payload"
	.asciz	"auto"
	.asciz	"async"
	.asciz	"naked"
	.asciz	"inline"
	.asciz	"x86_64_sysv"
	.asciz	"lang.CallingConvention.CommonOptions"
	.asciz	"incoming_stack_alignment"
	.asciz	"?u64"
	.asciz	"u64"
	.asciz	"some"
	.asciz	"x86_64_x32"
	.asciz	"x86_64_win"
	.asciz	"x86_64_regcall_v3_sysv"
	.asciz	"x86_64_regcall_v4_win"
	.asciz	"x86_64_vectorcall"
	.asciz	"x86_64_interrupt"
	.asciz	"x86_64_preserve_none"
	.asciz	"x86_sysv"
	.asciz	"lang.CallingConvention.X86RegparmOptions"
	.asciz	"register_params"
	.asciz	"x86_win"
	.asciz	"x86_mingw"
	.asciz	"x86_stdcall"
	.asciz	"x86_fastcall"
	.asciz	"x86_thiscall"
	.asciz	"x86_thiscall_mingw"
	.asciz	"x86_regcall_v3"
	.asciz	"x86_regcall_v4_win"
	.asciz	"x86_vectorcall"
	.asciz	"x86_interrupt"
	.asciz	"x86_16_cdecl"
	.asciz	"x86_16_stdcall"
	.asciz	"x86_16_regparmcall"
	.asciz	"x86_16_interrupt"
	.asciz	"aarch64_aapcs"
	.asciz	"aarch64_aapcs_darwin"
	.asciz	"aarch64_aapcs_win"
	.asciz	"aarch64_vfabi"
	.asciz	"aarch64_vfabi_sve"
	.asciz	"aarch64_preserve_none"
	.asciz	"alpha_osf"
	.asciz	"arm_aapcs"
	.asciz	"arm_aapcs_vfp"
	.asciz	"arm_interrupt"
	.asciz	"lang.CallingConvention.ArmInterruptOptions"
	.asciz	"type"
	.asciz	"lang.CallingConvention.ArmInterruptOptions.InterruptType"
	.asciz	"u3"
	.asciz	"generic"
	.asciz	"irq"
	.asciz	"fiq"
	.asciz	"swi"
	.asciz	"abort"
	.asciz	"undef"
	.asciz	"mips64_n64"
	.asciz	"mips64_n32"
	.asciz	"mips64_interrupt"
	.asciz	"lang.CallingConvention.MipsInterruptOptions"
	.asciz	"mode"
	.asciz	"lang.CallingConvention.MipsInterruptOptions.InterruptMode"
	.asciz	"eic"
	.asciz	"sw0"
	.asciz	"sw1"
	.asciz	"hw0"
	.asciz	"hw1"
	.asciz	"hw2"
	.asciz	"hw3"
	.asciz	"hw4"
	.asciz	"hw5"
	.asciz	"mips_o32"
	.asciz	"mips_interrupt"
	.asciz	"riscv64_lp64"
	.asciz	"riscv64_lp64_v"
	.asciz	"riscv64_interrupt"
	.asciz	"lang.CallingConvention.RiscvInterruptOptions"
	.asciz	"lang.CallingConvention.RiscvInterruptOptions.PrivilegeMode"
	.asciz	"supervisor"
	.asciz	"machine"
	.asciz	"riscv32_ilp32"
	.asciz	"riscv32_ilp32_v"
	.asciz	"riscv32_interrupt"
	.asciz	"sparc64_sysv"
	.asciz	"sparc_sysv"
	.asciz	"powerpc64_elf"
	.asciz	"powerpc64_elf_altivec"
	.asciz	"powerpc64_elf_v2"
	.asciz	"powerpc_sysv"
	.asciz	"powerpc_sysv_altivec"
	.asciz	"powerpc_aix"
	.asciz	"powerpc_aix_altivec"
	.asciz	"wasm_mvp"
	.asciz	"arc_sysv"
	.asciz	"arc_interrupt"
	.asciz	"lang.CallingConvention.ArcInterruptOptions"
	.asciz	"lang.CallingConvention.ArcInterruptOptions.InterruptType"
	.asciz	"ilink1"
	.asciz	"ilink2"
	.asciz	"ilink"
	.asciz	"firq"
	.asciz	"avr_gnu"
	.asciz	"avr_builtin"
	.asciz	"avr_signal"
	.asciz	"avr_interrupt"
	.asciz	"bpf_std"
	.asciz	"csky_sysv"
	.asciz	"csky_interrupt"
	.asciz	"hexagon_sysv"
	.asciz	"hexagon_sysv_hvx"
	.asciz	"hppa_elf"
	.asciz	"hppa64_elf"
	.asciz	"kvx_lp64"
	.asciz	"kvx_ilp32"
	.asciz	"lanai_sysv"
	.asciz	"loongarch64_lp64"
	.asciz	"loongarch32_ilp32"
	.asciz	"m68k_sysv"
	.asciz	"m68k_gnu"
	.asciz	"m68k_rtd"
	.asciz	"m68k_interrupt"
	.asciz	"m88k_sysv"
	.asciz	"microblaze_std"
	.asciz	"microblaze_interrupt"
	.asciz	"lang.CallingConvention.MicroblazeInterruptOptions"
	.asciz	"lang.CallingConvention.MicroblazeInterruptOptions.InterruptType"
	.asciz	"user"
	.asciz	"regular"
	.asciz	"fast"
	.asciz	"breakpoint"
	.asciz	"msp430_eabi"
	.asciz	"msp430_interrupt"
	.asciz	"or1k_sysv"
	.asciz	"propeller_sysv"
	.asciz	"s390x_sysv"
	.asciz	"s390x_sysv_vx"
	.asciz	"sh_gnu"
	.asciz	"sh_renesas"
	.asciz	"sh_interrupt"
	.asciz	"lang.CallingConvention.ShInterruptOptions"
	.asciz	"save"
	.asciz	"lang.CallingConvention.ShInterruptOptions.SaveBehavior"
	.asciz	"fpscr"
	.asciz	"high"
	.asciz	"full"
	.asciz	"bank"
	.asciz	"ve_sysv"
	.asciz	"xcore_xs1"
	.asciz	"xcore_xs2"
	.asciz	"xtensa_call0"
	.asciz	"xtensa_windowed"
	.asciz	"amdgcn_device"
	.asciz	"amdgcn_kernel"
	.asciz	"amdgcn_cs"
	.asciz	"nvptx_device"
	.asciz	"nvptx_kernel"
	.asciz	"spirv_device"
	.asciz	"spirv_vertex"
	.asciz	"spirv_kernel"
	.asciz	"lang.CallingConvention.SpirvKernelOptions"
	.asciz	"x"
	.asciz	"y"
	.asciz	"z"
	.asciz	"spirv_fragment"
	.asciz	"lang.CallingConvention.SpirvFragmentOptions"
	.asciz	"pixel_centered_integer"
	.asciz	"bool"
	.asciz	"depth_assumption"
	.asciz	"lang.CallingConvention.SpirvFragmentOptions.DepthAssumption"
	.asciz	"greater"
	.asciz	"less"
	.asciz	"unchanged"
	.asciz	"spirv_task"
	.asciz	"spirv_mesh"
	.asciz	"lang.CallingConvention.SpirvMeshOptions"
	.asciz	"max_primitives"
	.asciz	"max_vertices"
	.asciz	"stage_output"
	.asciz	"lang.CallingConvention.SpirvMeshOptions.StageOutput"
	.asciz	"output_points"
	.asciz	"output_lines"
	.asciz	"output_triangles"
	.asciz	"ez80_cet"
	.asciz	"ez80_tiflags"
	.asciz	"@typeInfo(lang.CallingConvention).@\"union\".tag_type.?"
	.asciz	"lang.CallingConvention.c"
	.asciz	"counter"
	.asciz	"hoist.counter"
	.asciz	"Target.DynamicLinker.none"
	.asciz	"apple_m5"
	.asciz	"Target.aarch64.cpu.apple_m5"
	.asciz	"hoist.tickPure"
	.asciz	"tickPure"
	.asciz	"sumPure"
	.asciz	"hoist.sumPure"
	.asciz	"cold2"
	.asciz	"hoist.cold2"
	.asciz	"sumNone"
	.asciz	"hoist.sumNone"
	.asciz	"hoist.tickNoMem"
	.asciz	"tickNoMem"
	.asciz	"sumNoMem"
	.asciz	"hoist.sumNoMem"
	.asciz	"cold"
	.asciz	"hoist.cold"
	.asciz	"hoist.tickMem"
	.asciz	"tickMem"
	.asciz	"sumMem"
	.asciz	"hoist.sumMem"
	.asciz	"s"
	.asciz	"*const hoist.S"
	.asciz	"hoist.S"
	.asciz	"[*]const u64"
	.asciz	"n"
	.asciz	"t"
	.asciz	"i"
	.section	__DWARF,__apple_names,regular,debug
Lnames_begin:
	.long	1212240712
	.short	1
	.short	0
	.long	10
	.long	20
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
	.long	5
	.long	6
	.long	7
	.long	11
	.long	17
	.long	2090155911
	.long	41845582
	.long	-1673287573
	.long	181894764
	.long	-811096522
	.long	480416345
	.long	-379162820
	.long	255668377
	.long	1380951167
	.long	1381029707
	.long	-977568639
	.long	372528878
	.long	1704932268
	.long	1968130298
	.long	-2103027228
	.long	-1326082838
	.long	-1326004298
	.long	-738903707
	.long	-680296287
	.long	-515093937
Lset174 = LNames14-Lnames_begin
	.long	Lset174
Lset175 = LNames17-Lnames_begin
	.long	Lset175
Lset176 = LNames11-Lnames_begin
	.long	Lset176
Lset177 = LNames4-Lnames_begin
	.long	Lset177
Lset178 = LNames10-Lnames_begin
	.long	Lset178
Lset179 = LNames16-Lnames_begin
	.long	Lset179
Lset180 = LNames15-Lnames_begin
	.long	Lset180
Lset181 = LNames6-Lnames_begin
	.long	Lset181
Lset182 = LNames9-Lnames_begin
	.long	Lset182
Lset183 = LNames3-Lnames_begin
	.long	Lset183
Lset184 = LNames13-Lnames_begin
	.long	Lset184
Lset185 = LNames7-Lnames_begin
	.long	Lset185
Lset186 = LNames12-Lnames_begin
	.long	Lset186
Lset187 = LNames1-Lnames_begin
	.long	Lset187
Lset188 = LNames19-Lnames_begin
	.long	Lset188
Lset189 = LNames8-Lnames_begin
	.long	Lset189
Lset190 = LNames2-Lnames_begin
	.long	Lset190
Lset191 = LNames0-Lnames_begin
	.long	Lset191
Lset192 = LNames5-Lnames_begin
	.long	Lset192
Lset193 = LNames18-Lnames_begin
	.long	Lset193
LNames14:
	.long	5343
	.long	1
	.long	5144
	.long	0
LNames17:
	.long	5388
	.long	1
	.long	5185
	.long	0
LNames11:
	.long	5328
	.long	1
	.long	5042
	.long	0
LNames4:
	.long	5222
	.long	1
	.long	4913
	.long	0
LNames10:
	.long	5319
	.long	1
	.long	5042
	.long	0
LNames16:
	.long	5381
	.long	1
	.long	5185
	.long	0
LNames15:
	.long	5348
	.long	1
	.long	5144
	.long	0
LNames6:
	.long	5253
	.long	1
	.long	4926
	.long	0
LNames9:
	.long	5279
	.long	1
	.long	4955
	.long	0
LNames3:
	.long	5239
	.long	1
	.long	4824
	.long	0
LNames13:
	.long	5293
	.long	1
	.long	5131
	.long	0
LNames7:
	.long	5259
	.long	1
	.long	4926
	.long	0
LNames12:
	.long	5309
	.long	1
	.long	5131
	.long	0
LNames1:
	.long	5130
	.long	1
	.long	4755
	.long	0
LNames19:
	.long	5359
	.long	1
	.long	5274
	.long	0
LNames8:
	.long	5271
	.long	1
	.long	4955
	.long	0
LNames2:
	.long	5231
	.long	1
	.long	4824
	.long	0
LNames0:
	.long	5122
	.long	1
	.long	4755
	.long	0
LNames5:
	.long	5207
	.long	1
	.long	4913
	.long	0
LNames18:
	.long	5373
	.long	1
	.long	5274
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
	.long	33
	.long	66
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
	.long	2
	.long	4
	.long	-1
	.long	6
	.long	9
	.long	-1
	.long	12
	.long	-1
	.long	-1
	.long	14
	.long	17
	.long	18
	.long	21
	.long	22
	.long	23
	.long	25
	.long	30
	.long	33
	.long	36
	.long	40
	.long	43
	.long	-1
	.long	47
	.long	49
	.long	-1
	.long	52
	.long	53
	.long	56
	.long	59
	.long	61
	.long	-1
	.long	64
	.long	-1403895574
	.long	-1015088947
	.long	-1578612786
	.long	-1027841796
	.long	-594775205
	.long	-72470246
	.long	166866319
	.long	277156213
	.long	356345851
	.long	294660338
	.long	2090120081
	.long	2101444097
	.long	219141787
	.long	-1759246464
	.long	1602849280
	.long	-965410407
	.long	-650976474
	.long	-1125488819
	.long	601724157
	.long	1067405604
	.long	-1680398602
	.long	-756291252
	.long	-1047197966
	.long	2088866883
	.long	-1746184330
	.long	46322347
	.long	1171449889
	.long	2082440926
	.long	-210447786
	.long	-205212468
	.long	5863820
	.long	193506143
	.long	1409415629
	.long	5863821
	.long	-1789355389
	.long	-835581370
	.long	5863822
	.long	193506244
	.long	1483373119
	.long	1728027265
	.long	5863823
	.long	252323894
	.long	1217226866
	.long	5863824
	.long	-1605296698
	.long	-365244412
	.long	-285621220
	.long	5863826
	.long	-1127173787
	.long	599991834
	.long	1159683120
	.long	-1917705550
	.long	604175213
	.long	644651892
	.long	1987743642
	.long	-1114449775
	.long	808000144
	.long	1669146133
	.long	-540490047
	.long	1428657248
	.long	1873467614
	.long	2090838615
	.long	-835578718
	.long	-800809093
	.long	1369559828
	.long	1828751066
Lset194 = Ltypes59-Ltypes_begin
	.long	Lset194
Lset195 = Ltypes25-Ltypes_begin
	.long	Lset195
Lset196 = Ltypes16-Ltypes_begin
	.long	Lset196
Lset197 = Ltypes2-Ltypes_begin
	.long	Lset197
Lset198 = Ltypes6-Ltypes_begin
	.long	Lset198
Lset199 = Ltypes32-Ltypes_begin
	.long	Lset199
Lset200 = Ltypes50-Ltypes_begin
	.long	Lset200
Lset201 = Ltypes5-Ltypes_begin
	.long	Lset201
Lset202 = Ltypes11-Ltypes_begin
	.long	Lset202
Lset203 = Ltypes8-Ltypes_begin
	.long	Lset203
Lset204 = Ltypes58-Ltypes_begin
	.long	Lset204
Lset205 = Ltypes55-Ltypes_begin
	.long	Lset205
Lset206 = Ltypes27-Ltypes_begin
	.long	Lset206
Lset207 = Ltypes48-Ltypes_begin
	.long	Lset207
Lset208 = Ltypes61-Ltypes_begin
	.long	Lset208
Lset209 = Ltypes43-Ltypes_begin
	.long	Lset209
Lset210 = Ltypes36-Ltypes_begin
	.long	Lset210
Lset211 = Ltypes65-Ltypes_begin
	.long	Lset211
Lset212 = Ltypes19-Ltypes_begin
	.long	Lset212
Lset213 = Ltypes35-Ltypes_begin
	.long	Lset213
Lset214 = Ltypes3-Ltypes_begin
	.long	Lset214
Lset215 = Ltypes34-Ltypes_begin
	.long	Lset215
Lset216 = Ltypes37-Ltypes_begin
	.long	Lset216
Lset217 = Ltypes40-Ltypes_begin
	.long	Lset217
Lset218 = Ltypes28-Ltypes_begin
	.long	Lset218
Lset219 = Ltypes0-Ltypes_begin
	.long	Lset219
Lset220 = Ltypes52-Ltypes_begin
	.long	Lset220
Lset221 = Ltypes53-Ltypes_begin
	.long	Lset221
Lset222 = Ltypes44-Ltypes_begin
	.long	Lset222
Lset223 = Ltypes51-Ltypes_begin
	.long	Lset223
Lset224 = Ltypes1-Ltypes_begin
	.long	Lset224
Lset225 = Ltypes26-Ltypes_begin
	.long	Lset225
Lset226 = Ltypes64-Ltypes_begin
	.long	Lset226
Lset227 = Ltypes45-Ltypes_begin
	.long	Lset227
Lset228 = Ltypes4-Ltypes_begin
	.long	Lset228
Lset229 = Ltypes30-Ltypes_begin
	.long	Lset229
Lset230 = Ltypes33-Ltypes_begin
	.long	Lset230
Lset231 = Ltypes41-Ltypes_begin
	.long	Lset231
Lset232 = Ltypes22-Ltypes_begin
	.long	Lset232
Lset233 = Ltypes56-Ltypes_begin
	.long	Lset233
Lset234 = Ltypes31-Ltypes_begin
	.long	Lset234
Lset235 = Ltypes38-Ltypes_begin
	.long	Lset235
Lset236 = Ltypes47-Ltypes_begin
	.long	Lset236
Lset237 = Ltypes17-Ltypes_begin
	.long	Lset237
Lset238 = Ltypes29-Ltypes_begin
	.long	Lset238
Lset239 = Ltypes62-Ltypes_begin
	.long	Lset239
Lset240 = Ltypes18-Ltypes_begin
	.long	Lset240
Lset241 = Ltypes12-Ltypes_begin
	.long	Lset241
Lset242 = Ltypes15-Ltypes_begin
	.long	Lset242
Lset243 = Ltypes21-Ltypes_begin
	.long	Lset243
Lset244 = Ltypes23-Ltypes_begin
	.long	Lset244
Lset245 = Ltypes46-Ltypes_begin
	.long	Lset245
Lset246 = Ltypes60-Ltypes_begin
	.long	Lset246
Lset247 = Ltypes57-Ltypes_begin
	.long	Lset247
Lset248 = Ltypes49-Ltypes_begin
	.long	Lset248
Lset249 = Ltypes10-Ltypes_begin
	.long	Lset249
Lset250 = Ltypes24-Ltypes_begin
	.long	Lset250
Lset251 = Ltypes39-Ltypes_begin
	.long	Lset251
Lset252 = Ltypes9-Ltypes_begin
	.long	Lset252
Lset253 = Ltypes42-Ltypes_begin
	.long	Lset253
Lset254 = Ltypes63-Ltypes_begin
	.long	Lset254
Lset255 = Ltypes20-Ltypes_begin
	.long	Lset255
Lset256 = Ltypes7-Ltypes_begin
	.long	Lset256
Lset257 = Ltypes14-Ltypes_begin
	.long	Lset257
Lset258 = Ltypes54-Ltypes_begin
	.long	Lset258
Lset259 = Ltypes13-Ltypes_begin
	.long	Lset259
Ltypes59:
	.long	4739
	.long	1
	.long	2742
	.short	4
	.byte	0
	.long	0
Ltypes25:
	.long	1097
	.long	1
	.long	897
	.short	19
	.byte	0
	.long	0
Ltypes16:
	.long	427
	.long	1
	.long	275
	.short	4
	.byte	0
	.long	0
Ltypes2:
	.long	150
	.long	1
	.long	113
	.short	36
	.byte	0
	.long	0
Ltypes6:
	.long	212
	.long	1
	.long	166
	.short	36
	.byte	0
	.long	0
Ltypes32:
	.long	2020
	.long	1
	.long	1907
	.short	4
	.byte	0
	.long	0
Ltypes50:
	.long	3644
	.long	1
	.long	2450
	.short	19
	.byte	0
	.long	0
Ltypes5:
	.long	206
	.long	1
	.long	159
	.short	36
	.byte	0
	.long	0
Ltypes11:
	.long	343
	.long	1
	.long	696
	.short	15
	.byte	0
	.long	0
Ltypes8:
	.long	282
	.long	1
	.long	657
	.short	15
	.byte	0
	.long	0
Ltypes58:
	.long	4717
	.long	1
	.long	4748
	.short	36
	.byte	0
	.long	0
Ltypes55:
	.long	4351
	.long	1
	.long	2626
	.short	4
	.byte	0
	.long	0
Ltypes27:
	.long	1145
	.long	1
	.long	941
	.short	4
	.byte	0
	.long	0
Ltypes48:
	.long	3298
	.long	1
	.long	2390
	.short	19
	.byte	0
	.long	0
Ltypes61:
	.long	4925
	.long	1
	.long	2858
	.short	4
	.byte	0
	.long	0
Ltypes43:
	.long	2906
	.long	1
	.long	2204
	.short	19
	.byte	0
	.long	0
Ltypes36:
	.long	2163
	.long	1
	.long	2098
	.short	1
	.byte	0
	.long	0
Ltypes65:
	.long	5426
	.long	1
	.long	5328
	.short	15
	.byte	0
	.long	0
Ltypes19:
	.long	921
	.long	1
	.long	803
	.short	23
	.byte	0
	.long	0
Ltypes35:
	.long	2135
	.long	1
	.long	2064
	.short	19
	.byte	0
	.long	0
Ltypes3:
	.long	169
	.long	1
	.long	120
	.short	19
	.byte	0
	.long	0
Ltypes34:
	.long	2108
	.long	1
	.long	1998
	.short	19
	.byte	0
	.long	0
Ltypes37:
	.long	2186
	.long	1
	.long	2129
	.short	19
	.byte	0
	.long	0
Ltypes40:
	.long	2346
	.long	1
	.long	4704
	.short	19
	.byte	0
	.long	0
Ltypes28:
	.long	1398
	.long	1
	.long	1206
	.short	19
	.byte	0
	.long	0
Ltypes0:
	.long	93
	.long	1
	.long	57
	.short	4
	.byte	0
	.long	0
Ltypes52:
	.long	4051
	.long	1
	.long	2522
	.short	19
	.byte	0
	.long	0
Ltypes53:
	.long	4101
	.long	1
	.long	2554
	.short	4
	.byte	0
	.long	0
Ltypes44:
	.long	2954
	.long	1
	.long	2236
	.short	4
	.byte	0
	.long	0
Ltypes51:
	.long	3687
	.long	1
	.long	2482
	.short	4
	.byte	0
	.long	0
Ltypes1:
	.long	109
	.long	1
	.long	90
	.short	36
	.byte	0
	.long	0
Ltypes26:
	.long	1133
	.long	1
	.long	1668
	.short	36
	.byte	0
	.long	0
Ltypes64:
	.long	5418
	.long	1
	.long	5296
	.short	19
	.byte	0
	.long	0
Ltypes45:
	.long	3011
	.long	1
	.long	4741
	.short	36
	.byte	0
	.long	0
Ltypes4:
	.long	197
	.long	1
	.long	143
	.short	1
	.byte	0
	.long	0
Ltypes30:
	.long	1766
	.long	1
	.long	1690
	.short	4
	.byte	0
	.long	0
Ltypes33:
	.long	2040
	.long	1
	.long	1976
	.short	36
	.byte	0
	.long	0
Ltypes41:
	.long	2351
	.long	1
	.long	4734
	.short	36
	.byte	0
	.long	0
Ltypes22:
	.long	987
	.long	1
	.long	1593
	.short	19
	.byte	0
	.long	0
Ltypes56:
	.long	4587
	.long	1
	.long	2666
	.short	19
	.byte	0
	.long	0
Ltypes31:
	.long	1777
	.long	1
	.long	1885
	.short	36
	.byte	0
	.long	0
Ltypes38:
	.long	2217
	.long	1
	.long	3584
	.short	23
	.byte	0
	.long	0
Ltypes47:
	.long	3134
	.long	1
	.long	2320
	.short	4
	.byte	0
	.long	0
Ltypes17:
	.long	443
	.long	1
	.long	761
	.short	36
	.byte	0
	.long	0
Ltypes29:
	.long	1433
	.long	1
	.long	1251
	.short	4
	.byte	0
	.long	0
Ltypes62:
	.long	5043
	.long	1
	.long	2903
	.short	4
	.byte	0
	.long	0
Ltypes18:
	.long	897
	.long	1
	.long	783
	.short	19
	.byte	0
	.long	0
Ltypes12:
	.long	355
	.long	1
	.long	705
	.short	36
	.byte	0
	.long	0
Ltypes15:
	.long	399
	.long	1
	.long	752
	.short	15
	.byte	0
	.long	0
Ltypes21:
	.long	961
	.long	1
	.long	1561
	.short	19
	.byte	0
	.long	0
Ltypes23:
	.long	1025
	.long	1
	.long	1658
	.short	22
	.byte	0
	.long	0
Ltypes46:
	.long	3085
	.long	1
	.long	2288
	.short	19
	.byte	0
	.long	0
Ltypes60:
	.long	4844
	.long	1
	.long	2782
	.short	19
	.byte	0
	.long	0
Ltypes57:
	.long	4650
	.long	1
	.long	2710
	.short	19
	.byte	0
	.long	0
Ltypes49:
	.long	3343
	.long	1
	.long	2422
	.short	4
	.byte	0
	.long	0
Ltypes10:
	.long	328
	.long	1
	.long	666
	.short	19
	.byte	0
	.long	0
Ltypes24:
	.long	1052
	.long	1
	.long	864
	.short	19
	.byte	0
	.long	0
Ltypes39:
	.long	2284
	.long	1
	.long	2149
	.short	19
	.byte	0
	.long	0
Ltypes9:
	.long	306
	.long	1
	.long	209
	.short	19
	.byte	0
	.long	0
Ltypes42:
	.long	2492
	.long	1
	.long	2171
	.short	19
	.byte	0
	.long	0
Ltypes63:
	.long	5403
	.long	1
	.long	5287
	.short	15
	.byte	0
	.long	0
Ltypes20:
	.long	949
	.long	1
	.long	1554
	.short	36
	.byte	0
	.long	0
Ltypes7:
	.long	265
	.long	1
	.long	188
	.short	19
	.byte	0
	.long	0
Ltypes14:
	.long	386
	.long	1
	.long	722
	.short	19
	.byte	0
	.long	0
Ltypes54:
	.long	4304
	.long	1
	.long	2594
	.short	19
	.byte	0
	.long	0
Ltypes13:
	.long	372
	.long	1
	.long	712
	.short	22
	.byte	0
	.long	0
.subsections_via_symbols
	.section	__DWARF,__debug_line,regular,debug
Lsection_line:
Lline_table_start0:
