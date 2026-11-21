	.intel_syntax noprefix
	.file	"abi"
	.file	1 "/Users/shreeve/.local/share/mise/installs/zig/0.17.0/lib" "std/lang.zig"
	.file	2 "/Users/shreeve/.cache/zig" "b/feb26d262e3352a3d9aced6c05eb68df/builtin.zig"
	.text
	.p2align	4
	.type	abi.call_viewed,@function
abi.call_viewed:
.Lfunc_begin0:
	.file	3 "/private/tmp/claude-501/-Users-shreeve-Data-Code-undat/6fff74ce-077f-4bc9-afce-9c419f622ac3/scratchpad/opts/zig" "abi.zig"
	.loc	3 18 0
	.cfi_startproc
	push	rbp
	.cfi_def_cfa_offset 16
	.cfi_offset rbp, -16
	mov	rbp, rsp
	.cfi_def_cfa_register rbp
	sub	rsp, 48
	mov	rdi, rsi
.Ltmp0:
	.loc	3 19 20 prologue_end
	mov	qword ptr [rbp - 40], rdx
	mov	qword ptr [rbp - 32], 3
	mov	byte ptr [rbp - 8], 1
	mov	qword ptr [rbp - 24], offset __anon_190
	mov	qword ptr [rbp - 16], 4
	lea	rsi, [rbp - 40]
.Ltmp1:
	.loc	3 19 18 is_stmt 0
	call	abi.viewed
.Ltmp2:
	.loc	3 19 5 epilogue_begin
	add	rsp, 48
	pop	rbp
	.cfi_def_cfa rsp, 8
	ret
.Ltmp3:
.Lfunc_end0:
	.size	abi.call_viewed, .Lfunc_end0-abi.call_viewed
	.cfi_endproc

	.p2align	4
	.type	abi.viewed,@function
abi.viewed:
.Lfunc_begin1:
	.loc	3 9 0 is_stmt 1
	.cfi_startproc
	push	rbp
	.cfi_def_cfa_offset 16
	.cfi_offset rbp, -16
	mov	rbp, rsp
	.cfi_def_cfa_register rbp
.Ltmp4:
	.loc	3 10 40 prologue_end
	add	rdi, qword ptr [rsi]
	.loc	3 10 54 is_stmt 0
	add	rdi, qword ptr [rsi + 8]
	movzx	eax, byte ptr [rsi + 32]
	.loc	3 10 68
	and	eax, 1
	add	rdi, qword ptr [rsi + 24]
	.loc	3 10 95
	add	rax, rdi
	.loc	3 10 5 epilogue_begin
	pop	rbp
	.cfi_def_cfa rsp, 8
	ret
.Ltmp5:
.Lfunc_end1:
	.size	abi.viewed, .Lfunc_end1-abi.viewed
	.cfi_endproc

	.p2align	4
	.type	abi.call_grouped,@function
abi.call_grouped:
.Lfunc_begin2:
	.loc	3 15 0 is_stmt 1
	.cfi_startproc
	push	rbp
	.cfi_def_cfa_offset 16
	.cfi_offset rbp, -16
	mov	rbp, rsp
	.cfi_def_cfa_register rbp
	sub	rsp, 48
	mov	rdi, rsi
.Ltmp6:
	.loc	3 16 21 prologue_end
	mov	qword ptr [rbp - 40], rdx
	mov	qword ptr [rbp - 32], 3
	mov	byte ptr [rbp - 8], 1
	mov	qword ptr [rbp - 24], offset __anon_190
	mov	qword ptr [rbp - 16], 4
	lea	rsi, [rbp - 40]
.Ltmp7:
	.loc	3 16 19 is_stmt 0
	call	abi.grouped
.Ltmp8:
	.loc	3 16 5 epilogue_begin
	add	rsp, 48
	pop	rbp
	.cfi_def_cfa rsp, 8
	ret
.Ltmp9:
.Lfunc_end2:
	.size	abi.call_grouped, .Lfunc_end2-abi.call_grouped
	.cfi_endproc

	.p2align	4
	.type	abi.grouped,@function
abi.grouped:
.Lfunc_begin3:
	.loc	3 6 0 is_stmt 1
	.cfi_startproc
	push	rbp
	.cfi_def_cfa_offset 16
	.cfi_offset rbp, -16
	mov	rbp, rsp
	.cfi_def_cfa_register rbp
.Ltmp10:
	.loc	3 7 40 prologue_end
	add	rdi, qword ptr [rsi]
	movzx	eax, byte ptr [rsi + 32]
	.loc	3 7 54 is_stmt 0
	add	rdi, qword ptr [rsi + 8]
	.loc	3 7 68
	and	eax, 1
	add	rdi, qword ptr [rsi + 24]
	.loc	3 7 95
	add	rax, rdi
	.loc	3 7 5 epilogue_begin
	pop	rbp
	.cfi_def_cfa rsp, 8
	ret
.Ltmp11:
.Lfunc_end3:
	.size	abi.grouped, .Lfunc_end3-abi.grouped
	.cfi_endproc

	.p2align	4
	.type	abi.call_flat,@function
abi.call_flat:
.Lfunc_begin4:
	.loc	3 12 0 is_stmt 1
	.cfi_startproc
	push	rbp
	.cfi_def_cfa_offset 16
	.cfi_offset rbp, -16
	mov	rbp, rsp
	.cfi_def_cfa_register rbp
	mov	rdi, rsi
.Ltmp12:
	.loc	3 13 16 prologue_end
	mov	rsi, rdx
.Ltmp13:
	.loc	3 13 16 epilogue_begin is_stmt 0
	pop	rbp
	.cfi_def_cfa rsp, 8
	jmp	abi.flat
.Ltmp14:
.Lfunc_end4:
	.size	abi.call_flat, .Lfunc_end4-abi.call_flat
	.cfi_endproc

	.p2align	4
	.type	abi.flat,@function
abi.flat:
.Lfunc_begin5:
	.loc	3 3 0 is_stmt 1
	.cfi_startproc
	push	rbp
	.cfi_def_cfa_offset 16
	.cfi_offset rbp, -16
	mov	rbp, rsp
	.cfi_def_cfa_register rbp
.Ltmp15:
	.loc	3 4 83 prologue_end
	lea	rax, [rdi + rsi]
	add	rax, 8
	.loc	3 4 5 epilogue_begin is_stmt 0
	pop	rbp
	.cfi_def_cfa rsp, 8
	ret
.Ltmp16:
.Lfunc_end5:
	.size	abi.flat, .Lfunc_end5-abi.flat
	.cfi_endproc

	.type	__anon_190,@object
	.section	.rodata.str1.1,"aMS",@progbits,1
__anon_190:
	.asciz	"anon"
	.size	__anon_190, 5

	.globl	call_viewed
	.type	call_viewed,@function
call_viewed = abi.call_viewed
	.globl	call_grouped
	.type	call_grouped,@function
call_grouped = abi.call_grouped
	.globl	call_flat
	.type	call_flat,@function
call_flat = abi.call_flat
	.section	.debug_loc,"",@progbits
.Ldebug_loc0:
	.quad	.Lfunc_begin0-.Lfunc_begin0
	.quad	.Ltmp1-.Lfunc_begin0
	.short	1
	.byte	84
	.quad	.Ltmp1-.Lfunc_begin0
	.quad	.Ltmp2-.Lfunc_begin0
	.short	1
	.byte	85
	.quad	.Ltmp2-.Lfunc_begin0
	.quad	.Lfunc_end0-.Lfunc_begin0
	.short	4
	.byte	243
	.byte	1
	.byte	84
	.byte	159
	.quad	0
	.quad	0
.Ldebug_loc1:
	.quad	.Lfunc_begin0-.Lfunc_begin0
	.quad	.Ltmp2-.Lfunc_begin0
	.short	1
	.byte	81
	.quad	.Ltmp2-.Lfunc_begin0
	.quad	.Lfunc_end0-.Lfunc_begin0
	.short	4
	.byte	243
	.byte	1
	.byte	81
	.byte	159
	.quad	0
	.quad	0
.Ldebug_loc2:
	.quad	.Lfunc_begin2-.Lfunc_begin0
	.quad	.Ltmp7-.Lfunc_begin0
	.short	1
	.byte	84
	.quad	.Ltmp7-.Lfunc_begin0
	.quad	.Ltmp8-.Lfunc_begin0
	.short	1
	.byte	85
	.quad	.Ltmp8-.Lfunc_begin0
	.quad	.Lfunc_end2-.Lfunc_begin0
	.short	4
	.byte	243
	.byte	1
	.byte	84
	.byte	159
	.quad	0
	.quad	0
.Ldebug_loc3:
	.quad	.Lfunc_begin2-.Lfunc_begin0
	.quad	.Ltmp8-.Lfunc_begin0
	.short	1
	.byte	81
	.quad	.Ltmp8-.Lfunc_begin0
	.quad	.Lfunc_end2-.Lfunc_begin0
	.short	4
	.byte	243
	.byte	1
	.byte	81
	.byte	159
	.quad	0
	.quad	0
.Ldebug_loc4:
	.quad	.Lfunc_begin4-.Lfunc_begin0
	.quad	.Ltmp13-.Lfunc_begin0
	.short	1
	.byte	84
	.quad	.Ltmp13-.Lfunc_begin0
	.quad	.Ltmp14-.Lfunc_begin0
	.short	1
	.byte	85
	.quad	0
	.quad	0
	.section	.debug_abbrev,"",@progbits
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
	.ascii	"\264B"
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
	.byte	0
	.byte	0
	.byte	7
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
	.section	.debug_info,"",@progbits
.Lcu_begin0:
	.long	.Ldebug_info_end0-.Ldebug_info_start0
.Ldebug_info_start0:
	.short	4
	.long	.debug_abbrev
	.byte	8
	.byte	1
	.long	.Linfo_string0
	.short	12
	.long	.Linfo_string1
	.long	.Lline_table_start0
	.long	.Linfo_string2

	.quad	.Lfunc_begin0
	.long	.Lfunc_end5-.Lfunc_begin0
	.byte	2
	.long	.Linfo_string3
	.long	57
	.byte	2
	.byte	6
	.long	.Linfo_string9
	.byte	3
	.long	90
	.long	.Linfo_string8
	.byte	1
	.byte	1
	.short	974
	.byte	1
	.byte	4
	.long	.Linfo_string5
	.byte	0
	.byte	4
	.long	.Linfo_string6
	.byte	1
	.byte	4
	.long	.Linfo_string7
	.byte	2
	.byte	0
	.byte	5
	.long	.Linfo_string4
	.byte	7
	.byte	1
	.byte	6
	.quad	.Lfunc_begin0
	.long	.Lfunc_end0-.Lfunc_begin0
	.byte	1
	.byte	86
	.long	.Linfo_string10
	.long	.Linfo_string11
	.byte	3
	.byte	18
	.long	430
	.byte	7
	.long	.Ldebug_loc0
	.long	.Linfo_string23
	.byte	3
	.byte	18
	.long	437
	.byte	7
	.long	.Ldebug_loc1
	.long	.Linfo_string25
	.byte	3
	.byte	18
	.long	430
	.byte	0
	.byte	6
	.quad	.Lfunc_begin1
	.long	.Lfunc_end1-.Lfunc_begin1
	.byte	1
	.byte	86
	.long	.Linfo_string13
	.long	.Linfo_string14
	.byte	3
	.byte	9
	.long	430
	.byte	8
	.byte	1
	.byte	84
	.long	.Linfo_string26
	.byte	3
	.byte	9
	.long	444
	.byte	0
	.byte	6
	.quad	.Lfunc_begin2
	.long	.Lfunc_end2-.Lfunc_begin2
	.byte	1
	.byte	86
	.long	.Linfo_string15
	.long	.Linfo_string16
	.byte	3
	.byte	15
	.long	430
	.byte	7
	.long	.Ldebug_loc2
	.long	.Linfo_string23
	.byte	3
	.byte	15
	.long	437
	.byte	7
	.long	.Ldebug_loc3
	.long	.Linfo_string25
	.byte	3
	.byte	15
	.long	430
	.byte	0
	.byte	6
	.quad	.Lfunc_begin3
	.long	.Lfunc_end3-.Lfunc_begin3
	.byte	1
	.byte	86
	.long	.Linfo_string17
	.long	.Linfo_string18
	.byte	3
	.byte	6
	.long	430
	.byte	8
	.byte	2
	.byte	116
	.byte	0
	.long	.Linfo_string26
	.byte	3
	.byte	6
	.long	453
	.byte	0
	.byte	6
	.quad	.Lfunc_begin4
	.long	.Lfunc_end4-.Lfunc_begin4
	.byte	1
	.byte	86
	.long	.Linfo_string19
	.long	.Linfo_string20
	.byte	3
	.byte	12
	.long	430
	.byte	7
	.long	.Ldebug_loc4
	.long	.Linfo_string23
	.byte	3
	.byte	12
	.long	437
	.byte	8
	.byte	1
	.byte	81
	.long	.Linfo_string25
	.byte	3
	.byte	12
	.long	430
	.byte	0
	.byte	9
	.quad	.Lfunc_begin5
	.long	.Lfunc_end5-.Lfunc_begin5
	.byte	1
	.byte	86
	.long	.Linfo_string21
	.long	.Linfo_string22
	.byte	3
	.byte	3
	.byte	3
	.long	430
	.byte	8
	.byte	1
	.byte	84
	.long	.Linfo_string27
	.byte	3
	.byte	3
	.long	430
	.byte	10
	.byte	3
	.long	.Linfo_string28
	.byte	3
	.byte	3
	.long	430
	.byte	11
	.byte	1
	.long	.Linfo_string35
	.byte	3
	.byte	3
	.long	553
	.byte	0
	.byte	5
	.long	.Linfo_string12
	.byte	5
	.byte	8
	.byte	5
	.long	.Linfo_string24
	.byte	7
	.byte	8
	.byte	12
	.long	453
	.long	.Linfo_string38
	.byte	13
	.long	.Linfo_string37
	.byte	40
	.byte	3
	.byte	1
	.byte	8
	.byte	14
	.long	.Linfo_string27
	.long	430
	.byte	8
	.byte	0
	.byte	14
	.long	.Linfo_string28
	.long	430
	.byte	8
	.byte	8
	.byte	14
	.long	.Linfo_string29
	.long	507
	.byte	8
	.byte	16
	.byte	14
	.long	.Linfo_string35
	.long	553
	.byte	1
	.byte	32
	.byte	0
	.byte	15
	.long	.Linfo_string34
	.byte	16
	.byte	8
	.byte	14
	.long	.Linfo_string30
	.long	537
	.byte	8
	.byte	0
	.byte	14
	.long	.Linfo_string33
	.long	437
	.byte	8
	.byte	8
	.byte	0
	.byte	12
	.long	546
	.long	.Linfo_string32
	.byte	5
	.long	.Linfo_string31
	.byte	7
	.byte	1
	.byte	5
	.long	.Linfo_string36
	.byte	2
	.byte	1
	.byte	0
.Ldebug_info_end0:
	.section	.debug_str,"MS",@progbits,1
.Linfo_string0:
	.asciz	"zig 0.17.0"
.Linfo_string1:
	.asciz	"abi"
.Linfo_string2:
	.asciz	"/private/tmp/claude-501/-Users-shreeve-Data-Code-undat/6fff74ce-077f-4bc9-afce-9c419f622ac3/scratchpad/opts/zig"
.Linfo_string3:
	.asciz	"output_mode"
.Linfo_string4:
	.asciz	"u2"
.Linfo_string5:
	.asciz	"Exe"
.Linfo_string6:
	.asciz	"Lib"
.Linfo_string7:
	.asciz	"Obj"
.Linfo_string8:
	.asciz	"lang.OutputMode"
.Linfo_string9:
	.asciz	"builtin.output_mode"
.Linfo_string10:
	.asciz	"abi.call_viewed"
.Linfo_string11:
	.asciz	"call_viewed"
.Linfo_string12:
	.asciz	"i64"
.Linfo_string13:
	.asciz	"abi.viewed"
.Linfo_string14:
	.asciz	"viewed"
.Linfo_string15:
	.asciz	"abi.call_grouped"
.Linfo_string16:
	.asciz	"call_grouped"
.Linfo_string17:
	.asciz	"abi.grouped"
.Linfo_string18:
	.asciz	"grouped"
.Linfo_string19:
	.asciz	"abi.call_flat"
.Linfo_string20:
	.asciz	"call_flat"
.Linfo_string21:
	.asciz	"abi.flat"
.Linfo_string22:
	.asciz	"flat"
.Linfo_string23:
	.asciz	"n"
.Linfo_string24:
	.asciz	"usize"
.Linfo_string25:
	.asciz	"t"
.Linfo_string26:
	.asciz	"net"
.Linfo_string27:
	.asciz	"timeout"
.Linfo_string28:
	.asciz	"retries"
.Linfo_string29:
	.asciz	"name"
.Linfo_string30:
	.asciz	"ptr"
.Linfo_string31:
	.asciz	"u8"
.Linfo_string32:
	.asciz	"[*]const u8"
.Linfo_string33:
	.asciz	"len"
.Linfo_string34:
	.asciz	"[]const u8"
.Linfo_string35:
	.asciz	"follow"
.Linfo_string36:
	.asciz	"bool"
.Linfo_string37:
	.asciz	"abi.Net"
.Linfo_string38:
	.asciz	"*const abi.Net"
	.section	.debug_pubnames,"",@progbits
	.long	.LpubNames_end0-.LpubNames_start0
.LpubNames_start0:
	.short	2
	.long	.Lcu_begin0
	.long	561
	.long	42
	.asciz	"output_mode"
	.long	71
	.asciz	"Exe"
	.long	77
	.asciz	"Lib"
	.long	83
	.asciz	"Obj"
	.long	97
	.asciz	"call_viewed"
	.long	157
	.asciz	"viewed"
	.long	200
	.asciz	"call_grouped"
	.long	260
	.asciz	"grouped"
	.long	304
	.asciz	"call_flat"
	.long	362
	.asciz	"flat"
	.long	0
.LpubNames_end0:
	.section	.debug_pubtypes,"",@progbits
	.long	.LpubTypes_end0-.LpubTypes_start0
.LpubTypes_start0:
	.short	2
	.long	.Lcu_begin0
	.long	561
	.long	57
	.asciz	"lang.OutputMode"
	.long	90
	.asciz	"u2"
	.long	430
	.asciz	"i64"
	.long	437
	.asciz	"usize"
	.long	444
	.asciz	"*const abi.Net"
	.long	453
	.asciz	"abi.Net"
	.long	507
	.asciz	"[]const u8"
	.long	537
	.asciz	"[*]const u8"
	.long	546
	.asciz	"u8"
	.long	553
	.asciz	"bool"
	.long	0
.LpubTypes_end0:
	.section	".note.GNU-stack","",@progbits
	.section	.debug_line,"",@progbits
.Lline_table_start0:
