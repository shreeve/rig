	.intel_syntax noprefix
	.file	"abi2"
	.file	1 "/Users/shreeve/.local/share/mise/installs/zig/0.17.0/lib" "std/lang.zig"
	.file	2 "/Users/shreeve/.cache/zig" "b/582861d596f0693a2acd07fa3a5df1b4/builtin.zig"
	.file	3 "/private/tmp/claude-501/-Users-shreeve-Data-Code-undat/6fff74ce-077f-4bc9-afce-9c419f622ac3/scratchpad/opts/zig" "abi2.zig"
	.text
	.p2align	4
	.type	abi2.call_flat_stored,@function
abi2.call_flat_stored:
.Lfunc_begin0:
	.loc	3 18 0
	.cfi_startproc
	push	rbp
	.cfi_def_cfa_offset 16
	.cfi_offset rbp, -16
	mov	rbp, rsp
	.cfi_def_cfa_register rbp
	sub	rsp, 16
.Ltmp0:
	.loc	3 19 22 prologue_end
	mov	rax, qword ptr [rdx]
	.loc	3 19 35 is_stmt 0
	mov	rcx, qword ptr [rdx + 8]
	.loc	3 19 60
	mov	r9, qword ptr [rdx + 16]
	mov	r10, qword ptr [rdx + 24]
	.loc	3 19 9
	mov	r8d, dword ptr [rdx + 32]
	mov	qword ptr [rsp], r10
	mov	rdx, rax
.Ltmp1:
	call	abi2.flat
.Ltmp2:
	.loc	3 19 9 epilogue_begin
	add	rsp, 16
	pop	rbp
	.cfi_def_cfa rsp, 8
	ret
.Ltmp3:
.Lfunc_end0:
	.size	abi2.call_flat_stored, .Lfunc_end0-abi2.call_flat_stored
	.cfi_endproc

	.p2align	4
	.type	abi2.flat,@function
abi2.flat:
.Lfunc_begin1:
	.loc	3 3 0 is_stmt 1
	.cfi_startproc
	push	rbp
	.cfi_def_cfa_offset 16
	.cfi_offset rbp, -16
	mov	rbp, rsp
	.cfi_def_cfa_register rbp
.Ltmp4:
	.loc	3 4 54 prologue_end
	add	rdi, rsi
	add	rdx, rcx
.Ltmp5:
	add	rdx, rdi
	and	r8d, 1
.Ltmp6:
	add	r8, rdx
	.loc	3 4 144 is_stmt 0
	add	r8, qword ptr [rbp + 16]
	.loc	3 4 176
	add	r8, r9
	add	qword ptr [rip + abi2.sink], r8
	.loc	3 4 176 epilogue_begin
	pop	rbp
	.cfi_def_cfa rsp, 8
	ret
.Ltmp7:
.Lfunc_end1:
	.size	abi2.flat, .Lfunc_end1-abi2.flat
	.cfi_endproc

	.p2align	4
	.type	abi2.call_grouped_stored,@function
abi2.call_grouped_stored:
.Lfunc_begin2:
	.loc	3 15 0 is_stmt 1
	.cfi_startproc
	push	rbp
	.cfi_def_cfa_offset 16
	.cfi_offset rbp, -16
	mov	rbp, rsp
	.cfi_def_cfa_register rbp
	sub	rsp, 48
.Ltmp8:
	.loc	3 16 14 prologue_end
	mov	rax, qword ptr [rdx + 32]
	mov	qword ptr [rbp - 16], rax
	movups	xmm0, xmmword ptr [rdx]
	movups	xmm1, xmmword ptr [rdx + 16]
	movaps	xmmword ptr [rbp - 32], xmm1
	movaps	xmmword ptr [rbp - 48], xmm0
	lea	rdx, [rbp - 48]
.Ltmp9:
	.loc	3 16 12 is_stmt 0
	call	abi2.grouped
.Ltmp10:
	.loc	3 16 12 epilogue_begin
	add	rsp, 48
	pop	rbp
	.cfi_def_cfa rsp, 8
	ret
.Ltmp11:
.Lfunc_end2:
	.size	abi2.call_grouped_stored, .Lfunc_end2-abi2.call_grouped_stored
	.cfi_endproc

	.p2align	4
	.type	abi2.grouped,@function
abi2.grouped:
.Lfunc_begin3:
	.loc	3 6 0 is_stmt 1
	.cfi_startproc
	push	rbp
	.cfi_def_cfa_offset 16
	.cfi_offset rbp, -16
	mov	rbp, rsp
	.cfi_def_cfa_register rbp
.Ltmp12:
	.loc	3 7 54 prologue_end
	add	rdi, rsi
	.loc	3 7 92 is_stmt 0
	add	rdi, qword ptr [rdx]
	movzx	eax, byte ptr [rdx + 32]
	.loc	3 7 107
	add	rdi, qword ptr [rdx + 8]
	.loc	3 7 135
	and	eax, 1
	add	rdi, qword ptr [rdx + 24]
	.loc	3 7 156
	add	rdi, qword ptr [rdx + 16]
	.loc	3 7 192
	add	rdi, qword ptr [rip + abi2.sink]
	add	rdi, rax
	mov	qword ptr [rip + abi2.sink], rdi
	.loc	3 7 192 epilogue_begin
	pop	rbp
	.cfi_def_cfa rsp, 8
	ret
.Ltmp13:
.Lfunc_end3:
	.size	abi2.grouped, .Lfunc_end3-abi2.grouped
	.cfi_endproc

	.p2align	4
	.type	abi2.call_grouped,@function
abi2.call_grouped:
.Lfunc_begin4:
	.loc	3 12 0 is_stmt 1
	.cfi_startproc
	push	rbp
	.cfi_def_cfa_offset 16
	.cfi_offset rbp, -16
	mov	rbp, rsp
	.cfi_def_cfa_register rbp
	sub	rsp, 48
.Ltmp14:
	mov	rax, qword ptr [rbp + 16]
.Ltmp15:
	.loc	3 13 75 prologue_end
	mov	qword ptr [rbp - 40], rdx
	mov	qword ptr [rbp - 32], rcx
	and	r8b, 1
.Ltmp16:
	mov	byte ptr [rbp - 8], r8b
	mov	qword ptr [rbp - 24], r9
	mov	qword ptr [rbp - 16], rax
	lea	rdx, [rbp - 40]
.Ltmp17:
	.loc	3 13 12 is_stmt 0
	call	abi2.grouped
.Ltmp18:
	.loc	3 13 12 epilogue_begin
	add	rsp, 48
	pop	rbp
	.cfi_def_cfa rsp, 8
	ret
.Ltmp19:
.Lfunc_end4:
	.size	abi2.call_grouped, .Lfunc_end4-abi2.call_grouped
	.cfi_endproc

	.p2align	4
	.type	abi2.call_flat,@function
abi2.call_flat:
.Lfunc_begin5:
	.loc	3 9 0 is_stmt 1
	.cfi_startproc
	push	rbp
	.cfi_def_cfa_offset 16
	.cfi_offset rbp, -16
	mov	rbp, rsp
	.cfi_def_cfa_register rbp
.Ltmp20:
	.loc	3 10 9 prologue_end epilogue_begin
	pop	rbp
	.cfi_def_cfa rsp, 8
	jmp	abi2.flat
.Ltmp21:
.Lfunc_end5:
	.size	abi2.call_flat, .Lfunc_end5-abi2.call_flat
	.cfi_endproc

	.type	abi2.sink,@object
	.local	abi2.sink
	.comm	abi2.sink,8,8
	.globl	call_flat_stored
	.type	call_flat_stored,@function
call_flat_stored = abi2.call_flat_stored
	.globl	call_grouped_stored
	.type	call_grouped_stored,@function
call_grouped_stored = abi2.call_grouped_stored
	.globl	call_grouped
	.type	call_grouped,@function
call_grouped = abi2.call_grouped
	.globl	call_flat
	.type	call_flat,@function
call_flat = abi2.call_flat
	.section	.debug_loc,"",@progbits
.Ldebug_loc0:
	.quad	.Lfunc_begin0-.Lfunc_begin0
	.quad	.Ltmp2-.Lfunc_begin0
	.short	1
	.byte	85
	.quad	.Ltmp2-.Lfunc_begin0
	.quad	.Lfunc_end0-.Lfunc_begin0
	.short	4
	.byte	243
	.byte	1
	.byte	85
	.byte	159
	.quad	0
	.quad	0
.Ldebug_loc1:
	.quad	.Lfunc_begin0-.Lfunc_begin0
	.quad	.Ltmp2-.Lfunc_begin0
	.short	1
	.byte	84
	.quad	.Ltmp2-.Lfunc_begin0
	.quad	.Lfunc_end0-.Lfunc_begin0
	.short	4
	.byte	243
	.byte	1
	.byte	84
	.byte	159
	.quad	0
	.quad	0
.Ldebug_loc2:
	.quad	.Lfunc_begin0-.Lfunc_begin0
	.quad	.Ltmp1-.Lfunc_begin0
	.short	1
	.byte	81
	.quad	.Ltmp1-.Lfunc_begin0
	.quad	.Lfunc_end0-.Lfunc_begin0
	.short	4
	.byte	243
	.byte	1
	.byte	81
	.byte	159
	.quad	0
	.quad	0
.Ldebug_loc3:
	.quad	.Lfunc_begin1-.Lfunc_begin0
	.quad	.Ltmp5-.Lfunc_begin0
	.short	1
	.byte	81
	.quad	.Ltmp5-.Lfunc_begin0
	.quad	.Lfunc_end1-.Lfunc_begin0
	.short	4
	.byte	243
	.byte	1
	.byte	81
	.byte	159
	.quad	0
	.quad	0
.Ldebug_loc4:
	.quad	.Lfunc_begin1-.Lfunc_begin0
	.quad	.Ltmp6-.Lfunc_begin0
	.short	1
	.byte	88
	.quad	.Ltmp6-.Lfunc_begin0
	.quad	.Lfunc_end1-.Lfunc_begin0
	.short	4
	.byte	243
	.byte	1
	.byte	88
	.byte	159
	.quad	0
	.quad	0
.Ldebug_loc5:
	.quad	.Lfunc_begin2-.Lfunc_begin0
	.quad	.Ltmp10-.Lfunc_begin0
	.short	1
	.byte	85
	.quad	.Ltmp10-.Lfunc_begin0
	.quad	.Lfunc_end2-.Lfunc_begin0
	.short	4
	.byte	243
	.byte	1
	.byte	85
	.byte	159
	.quad	0
	.quad	0
.Ldebug_loc6:
	.quad	.Lfunc_begin2-.Lfunc_begin0
	.quad	.Ltmp10-.Lfunc_begin0
	.short	1
	.byte	84
	.quad	.Ltmp10-.Lfunc_begin0
	.quad	.Lfunc_end2-.Lfunc_begin0
	.short	4
	.byte	243
	.byte	1
	.byte	84
	.byte	159
	.quad	0
	.quad	0
.Ldebug_loc7:
	.quad	.Lfunc_begin2-.Lfunc_begin0
	.quad	.Ltmp9-.Lfunc_begin0
	.short	1
	.byte	81
	.quad	.Ltmp9-.Lfunc_begin0
	.quad	.Lfunc_end2-.Lfunc_begin0
	.short	4
	.byte	243
	.byte	1
	.byte	81
	.byte	159
	.quad	0
	.quad	0
.Ldebug_loc8:
	.quad	.Lfunc_begin4-.Lfunc_begin0
	.quad	.Ltmp18-.Lfunc_begin0
	.short	1
	.byte	85
	.quad	.Ltmp18-.Lfunc_begin0
	.quad	.Lfunc_end4-.Lfunc_begin0
	.short	4
	.byte	243
	.byte	1
	.byte	85
	.byte	159
	.quad	0
	.quad	0
.Ldebug_loc9:
	.quad	.Lfunc_begin4-.Lfunc_begin0
	.quad	.Ltmp18-.Lfunc_begin0
	.short	1
	.byte	84
	.quad	.Ltmp18-.Lfunc_begin0
	.quad	.Lfunc_end4-.Lfunc_begin0
	.short	4
	.byte	243
	.byte	1
	.byte	84
	.byte	159
	.quad	0
	.quad	0
.Ldebug_loc10:
	.quad	.Lfunc_begin4-.Lfunc_begin0
	.quad	.Ltmp17-.Lfunc_begin0
	.short	1
	.byte	81
	.quad	.Ltmp17-.Lfunc_begin0
	.quad	.Lfunc_end4-.Lfunc_begin0
	.short	4
	.byte	243
	.byte	1
	.byte	81
	.byte	159
	.quad	0
	.quad	0
.Ldebug_loc11:
	.quad	.Lfunc_begin4-.Lfunc_begin0
	.quad	.Ltmp18-.Lfunc_begin0
	.short	1
	.byte	82
	.quad	.Ltmp18-.Lfunc_begin0
	.quad	.Lfunc_end4-.Lfunc_begin0
	.short	4
	.byte	243
	.byte	1
	.byte	82
	.byte	159
	.quad	0
	.quad	0
.Ldebug_loc12:
	.quad	.Lfunc_begin4-.Lfunc_begin0
	.quad	.Ltmp16-.Lfunc_begin0
	.short	1
	.byte	88
	.quad	.Ltmp16-.Lfunc_begin0
	.quad	.Lfunc_end4-.Lfunc_begin0
	.short	4
	.byte	243
	.byte	1
	.byte	88
	.byte	159
	.quad	0
	.quad	0
.Ldebug_loc13:
	.quad	.Lfunc_begin4-.Lfunc_begin0
	.quad	.Ltmp18-.Lfunc_begin0
	.short	1
	.byte	89
	.quad	.Ltmp18-.Lfunc_begin0
	.quad	.Lfunc_end4-.Lfunc_begin0
	.short	4
	.byte	243
	.byte	1
	.byte	89
	.byte	159
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
	.byte	0
	.byte	0
	.byte	8
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
	.byte	9
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
	.long	.Linfo_string10
	.long	122
	.byte	3
	.byte	2
	.byte	9
	.byte	3
	.quad	abi2.sink
	.long	.Linfo_string12
	.byte	5
	.long	.Linfo_string11
	.byte	5
	.byte	8
	.byte	7
	.quad	.Lfunc_begin0
	.long	.Lfunc_end0-.Lfunc_begin0
	.byte	1
	.byte	86
	.long	.Linfo_string13
	.long	.Linfo_string14
	.byte	3
	.byte	18
	.long	652
	.byte	8
	.long	.Ldebug_loc0
	.long	.Linfo_string26
	.byte	3
	.byte	18
	.long	659
	.byte	8
	.long	.Ldebug_loc1
	.long	.Linfo_string29
	.byte	3
	.byte	18
	.long	675
	.byte	8
	.long	.Ldebug_loc2
	.long	.Linfo_string31
	.byte	3
	.byte	18
	.long	682
	.byte	0
	.byte	7
	.quad	.Lfunc_begin1
	.long	.Lfunc_end1-.Lfunc_begin1
	.byte	1
	.byte	86
	.long	.Linfo_string16
	.long	.Linfo_string17
	.byte	3
	.byte	3
	.long	652
	.byte	8
	.long	.Ldebug_loc3
	.long	.Linfo_string32
	.byte	3
	.byte	3
	.long	122
	.byte	9
	.byte	1
	.byte	82
	.long	.Linfo_string33
	.byte	3
	.byte	3
	.long	122
	.byte	8
	.long	.Ldebug_loc4
	.long	.Linfo_string38
	.byte	3
	.byte	3
	.long	775
	.byte	0
	.byte	7
	.quad	.Lfunc_begin2
	.long	.Lfunc_end2-.Lfunc_begin2
	.byte	1
	.byte	86
	.long	.Linfo_string18
	.long	.Linfo_string19
	.byte	3
	.byte	15
	.long	652
	.byte	8
	.long	.Ldebug_loc5
	.long	.Linfo_string26
	.byte	3
	.byte	15
	.long	659
	.byte	8
	.long	.Ldebug_loc6
	.long	.Linfo_string29
	.byte	3
	.byte	15
	.long	675
	.byte	8
	.long	.Ldebug_loc7
	.long	.Linfo_string31
	.byte	3
	.byte	15
	.long	682
	.byte	0
	.byte	7
	.quad	.Lfunc_begin3
	.long	.Lfunc_end3-.Lfunc_begin3
	.byte	1
	.byte	86
	.long	.Linfo_string20
	.long	.Linfo_string21
	.byte	3
	.byte	6
	.long	652
	.byte	9
	.byte	2
	.byte	113
	.byte	0
	.long	.Linfo_string31
	.byte	3
	.byte	6
	.long	691
	.byte	0
	.byte	7
	.quad	.Lfunc_begin4
	.long	.Lfunc_end4-.Lfunc_begin4
	.byte	1
	.byte	86
	.long	.Linfo_string22
	.long	.Linfo_string23
	.byte	3
	.byte	12
	.long	652
	.byte	8
	.long	.Ldebug_loc8
	.long	.Linfo_string26
	.byte	3
	.byte	12
	.long	659
	.byte	8
	.long	.Ldebug_loc9
	.long	.Linfo_string29
	.byte	3
	.byte	12
	.long	675
	.byte	8
	.long	.Ldebug_loc10
	.long	.Linfo_string42
	.byte	3
	.byte	12
	.long	122
	.byte	8
	.long	.Ldebug_loc11
	.long	.Linfo_string43
	.byte	3
	.byte	12
	.long	122
	.byte	8
	.long	.Ldebug_loc12
	.long	.Linfo_string44
	.byte	3
	.byte	12
	.long	775
	.byte	8
	.long	.Ldebug_loc13
	.long	.Linfo_string45
	.byte	3
	.byte	12
	.long	659
	.byte	9
	.byte	2
	.byte	145
	.byte	16
	.long	.Linfo_string46
	.byte	3
	.byte	12
	.long	675
	.byte	0
	.byte	7
	.quad	.Lfunc_begin5
	.long	.Lfunc_end5-.Lfunc_begin5
	.byte	1
	.byte	86
	.long	.Linfo_string24
	.long	.Linfo_string25
	.byte	3
	.byte	9
	.long	652
	.byte	9
	.byte	1
	.byte	85
	.long	.Linfo_string26
	.byte	3
	.byte	9
	.long	659
	.byte	9
	.byte	1
	.byte	84
	.long	.Linfo_string29
	.byte	3
	.byte	9
	.long	675
	.byte	9
	.byte	1
	.byte	81
	.long	.Linfo_string42
	.byte	3
	.byte	9
	.long	122
	.byte	9
	.byte	1
	.byte	82
	.long	.Linfo_string43
	.byte	3
	.byte	9
	.long	122
	.byte	9
	.byte	1
	.byte	88
	.long	.Linfo_string44
	.byte	3
	.byte	9
	.long	775
	.byte	9
	.byte	1
	.byte	89
	.long	.Linfo_string45
	.byte	3
	.byte	9
	.long	659
	.byte	9
	.byte	2
	.byte	145
	.byte	16
	.long	.Linfo_string46
	.byte	3
	.byte	9
	.long	675
	.byte	0
	.byte	5
	.long	.Linfo_string15
	.byte	5
	.byte	0
	.byte	10
	.long	668
	.long	.Linfo_string28
	.byte	5
	.long	.Linfo_string27
	.byte	7
	.byte	1
	.byte	5
	.long	.Linfo_string30
	.byte	7
	.byte	8
	.byte	10
	.long	691
	.long	.Linfo_string41
	.byte	11
	.long	.Linfo_string40
	.byte	40
	.byte	3
	.byte	1
	.byte	8
	.byte	12
	.long	.Linfo_string32
	.long	122
	.byte	8
	.byte	0
	.byte	12
	.long	.Linfo_string33
	.long	122
	.byte	8
	.byte	8
	.byte	12
	.long	.Linfo_string34
	.long	745
	.byte	8
	.byte	16
	.byte	12
	.long	.Linfo_string38
	.long	775
	.byte	1
	.byte	32
	.byte	0
	.byte	13
	.long	.Linfo_string37
	.byte	16
	.byte	8
	.byte	12
	.long	.Linfo_string35
	.long	659
	.byte	8
	.byte	0
	.byte	12
	.long	.Linfo_string36
	.long	675
	.byte	8
	.byte	8
	.byte	0
	.byte	5
	.long	.Linfo_string39
	.byte	2
	.byte	1
	.byte	0
.Ldebug_info_end0:
	.section	.debug_str,"MS",@progbits,1
.Linfo_string0:
	.asciz	"zig 0.17.0"
.Linfo_string1:
	.asciz	"abi2"
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
	.asciz	"sink"
.Linfo_string11:
	.asciz	"i64"
.Linfo_string12:
	.asciz	"abi2.sink"
.Linfo_string13:
	.asciz	"abi2.call_flat_stored"
.Linfo_string14:
	.asciz	"call_flat_stored"
.Linfo_string15:
	.asciz	"void"
.Linfo_string16:
	.asciz	"abi2.flat"
.Linfo_string17:
	.asciz	"flat"
.Linfo_string18:
	.asciz	"abi2.call_grouped_stored"
.Linfo_string19:
	.asciz	"call_grouped_stored"
.Linfo_string20:
	.asciz	"abi2.grouped"
.Linfo_string21:
	.asciz	"grouped"
.Linfo_string22:
	.asciz	"abi2.call_grouped"
.Linfo_string23:
	.asciz	"call_grouped"
.Linfo_string24:
	.asciz	"abi2.call_flat"
.Linfo_string25:
	.asciz	"call_flat"
.Linfo_string26:
	.asciz	"p"
.Linfo_string27:
	.asciz	"u8"
.Linfo_string28:
	.asciz	"[*]const u8"
.Linfo_string29:
	.asciz	"n"
.Linfo_string30:
	.asciz	"usize"
.Linfo_string31:
	.asciz	"net"
.Linfo_string32:
	.asciz	"timeout"
.Linfo_string33:
	.asciz	"retries"
.Linfo_string34:
	.asciz	"name"
.Linfo_string35:
	.asciz	"ptr"
.Linfo_string36:
	.asciz	"len"
.Linfo_string37:
	.asciz	"[]const u8"
.Linfo_string38:
	.asciz	"follow"
.Linfo_string39:
	.asciz	"bool"
.Linfo_string40:
	.asciz	"abi2.Net"
.Linfo_string41:
	.asciz	"*const abi2.Net"
.Linfo_string42:
	.asciz	"t"
.Linfo_string43:
	.asciz	"r"
.Linfo_string44:
	.asciz	"f"
.Linfo_string45:
	.asciz	"q"
.Linfo_string46:
	.asciz	"m"
	.section	.debug_pubnames,"",@progbits
	.long	.LpubNames_end0-.LpubNames_start0
.LpubNames_start0:
	.short	2
	.long	.Lcu_begin0
	.long	783
	.long	42
	.asciz	"output_mode"
	.long	71
	.asciz	"Exe"
	.long	77
	.asciz	"Lib"
	.long	83
	.asciz	"Obj"
	.long	97
	.asciz	"sink"
	.long	129
	.asciz	"call_flat_stored"
	.long	204
	.asciz	"flat"
	.long	277
	.asciz	"call_grouped_stored"
	.long	352
	.asciz	"grouped"
	.long	396
	.asciz	"call_grouped"
	.long	530
	.asciz	"call_flat"
	.long	0
.LpubNames_end0:
	.section	.debug_pubtypes,"",@progbits
	.long	.LpubTypes_end0-.LpubTypes_start0
.LpubTypes_start0:
	.short	2
	.long	.Lcu_begin0
	.long	783
	.long	57
	.asciz	"lang.OutputMode"
	.long	90
	.asciz	"u2"
	.long	122
	.asciz	"i64"
	.long	652
	.asciz	"void"
	.long	659
	.asciz	"[*]const u8"
	.long	668
	.asciz	"u8"
	.long	675
	.asciz	"usize"
	.long	682
	.asciz	"*const abi2.Net"
	.long	691
	.asciz	"abi2.Net"
	.long	745
	.asciz	"[]const u8"
	.long	775
	.asciz	"bool"
	.long	0
.LpubTypes_end0:
	.section	".note.GNU-stack","",@progbits
	.section	.debug_line,"",@progbits
.Lline_table_start0:
