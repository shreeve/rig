
p-0xADDR00-0.bin:	file format mach-o arm64

Disassembly of section __TEXT,__text:

000000010001b97c <_rig.unordered.Unordered(i64,i64).rehash>:
10001b97c:     	stp	x28, x27, [sp, #-0x60]!
10001b980:     	stp	x26, x25, [sp, #0x10]
10001b984:     	stp	x24, x23, [sp, #0x20]
10001b988:     	stp	x22, x21, [sp, #0x30]
10001b98c:     	stp	x20, x19, [sp, #0x40]
10001b990:     	stp	x29, x30, [sp, #0x50]
10001b994:     	mov	x19, x0
10001b998:     	mov	x8, #0x2493             ; =9363
10001b99c:     	movk	x8, #0x9249, lsl #16
10001b9a0:     	movk	x8, #0x4924, lsl #32
10001b9a4:     	movk	x8, #0x2492, lsl #48
10001b9a8:     	umulh	x8, x1, x8
10001b9ac:     	sub	x9, x1, x8
10001b9b0:     	add	x8, x8, x9, lsr #1
10001b9b4:     	lsr	x8, x8, #2
10001b9b8:     	umax	x8, x8, #0x3
10001b9bc:     	clz	x25, x8
10001b9c0:     	mov	w26, #0x40              ; =64
10001b9c4:     	sub	w21, w26, w25
10001b9c8:     	mov	w8, #0x78               ; =120
10001b9cc:     	lsl	x8, x8, x21
10001b9d0:     	and	x1, x8, #0xfffffffffffffff0
10001b9d4:     	mov	w2, #0x3                ; =3
10001b9d8:     	bl	0x10002cad4 <_rig.alloc.alloc>
10001b9dc:     	cbz	x0, 0x10001bc88 <_rig.unordered.Unordered(i64,i64).rehash+0x30c>
10001b9e0:     	mov	x20, x0
10001b9e4:     	and	x8, x21, #0xffff
10001b9e8:     	mov	w24, #0x1               ; =1
10001b9ec:     	lsl	x9, x24, x8
10001b9f0:     	tst	x8, #0x40
10001b9f4:     	csel	x23, xzr, x9, ne
10001b9f8:     	mov	w9, #0x70               ; =112
10001b9fc:     	lsl	x8, x9, x8
10001ba00:     	add	x8, x0, x8
10001ba04:     	sub	x8, x8, #0x10
10001ba08:     	neg	w9, w8
10001ba0c:     	and	x9, x9, #0x7
10001ba10:     	add	x21, x9, x8
10001ba14:     	lsl	x1, x23, #3
10001ba18:     	mov	x0, x21
10001ba1c:     	bl	0x10002edb0 <dyld_stub_binder+0x10002edb0>
10001ba20:     	sub	x23, x23, #0x1
10001ba24:     	add	x8, x21, x23, lsl #3
10001ba28:     	strb	w24, [x8, #0x6]
10001ba2c:     	neg	w8, w25
10001ba30:     	and	w8, w8, #0x3f
10001ba34:     	sub	w25, w26, w8
10001ba38:     	ldr	x8, [x19, #0x8]
10001ba3c:     	cbz	x8, 0x10001bc38 <_rig.unordered.Unordered(i64,i64).rehash+0x2bc>
10001ba40:     	mov	x10, #0x0               ; =0
10001ba44:     	mov	x9, #0x0                ; =0
10001ba48:     	mov	x1, #0x0                ; =0
10001ba4c:     	mov	x11, #0x101010101010101 ; =72340172838076673
10001ba50:     	movk	x11, #0x1, lsl #48
10001ba54:     	ldr	x12, [x19, #0x10]
10001ba58:     	mov	x2, #-0x1               ; =-1
10001ba5c:     	movi.8b	v0, #0x1
10001ba60:     	mov	w13, #0x70              ; =112
10001ba64:     	mov	x14, #0xd4a3            ; =54435
10001ba68:     	movk	x14, #0xd433, lsl #16
10001ba6c:     	movk	x14, #0xa62e, lsl #32
10001ba70:     	movk	x14, #0x4b33, lsl #48
10001ba74:     	adrp	x15, 0x100030000 <dyld_stub_binder+0x100030000>
10001ba78:     	add	x15, x15, #0x73b
10001ba7c:     	mov	w16, #0x6               ; =6
10001ba80:     	mov	x17, #-0x1              ; =-1
10001ba84:     	adrp	x0, 0x100031000 <___anon_5843+0x8>
10001ba88:     	add	x0, x0, #0x10
10001ba8c:     	b	0x10001baac <_rig.unordered.Unordered(i64,i64).rehash+0x130>
10001ba90:     	mov	x26, x1
10001ba94:     	mov	x5, x2
10001ba98:     	mov	x2, x5
10001ba9c:     	mov	x1, x26
10001baa0:     	cmp	x10, x12
10001baa4:     	add	x10, x10, #0x1
10001baa8:     	b.eq	0x10001bc14 <_rig.unordered.Unordered(i64,i64).rehash+0x298>
10001baac:     	ldr	x3, [x19]
10001bab0:     	ldr	d1, [x3, x10, lsl #3]
10001bab4:     	cmhi.8b	v1, v1, v0
10001bab8:     	fmov	x3, d1
10001babc:     	ands	x3, x3, x11
10001bac0:     	b.eq	0x10001ba90 <_rig.unordered.Unordered(i64,i64).rehash+0x114>
10001bac4:     	madd	x4, x10, x13, x8
10001bac8:     	ctz	x5, x3
10001bacc:     	lsl	x5, x5, #1
10001bad0:     	and	x6, x5, #0xf0
10001bad4:     	ldr	x5, [x4, x6]
10001bad8:     	mul	x5, x5, x14
10001badc:     	ror	x7, x5, #0x38
10001bae0:     	lsr	x5, x7, x25
10001bae4:     	and	x7, x7, #0xff
10001bae8:     	ldrb	w7, [x15, x7]
10001baec:     	cmp	x5, x2
10001baf0:     	csel	x28, x1, x9, eq
10001baf4:     	cset	w26, eq
10001baf8:     	cmp	x5, x17
10001bafc:     	add	x27, x21, x5, lsl #3
10001bb00:     	csinc	w22, w26, wzr, ne
10001bb04:     	cmp	w22, #0x0
10001bb08:     	csel	x26, x0, x27, ne
10001bb0c:     	ldr	d1, [x26]
10001bb10:     	cmeq.8b	v1, v1, #0
10001bb14:     	fmov	x26, d1
10001bb18:     	and	x30, x26, x11
10001bb1c:     	ctz	x26, x30
10001bb20:     	lsr	x26, x26, #3
10001bb24:     	csinc	x26, x26, x28, eq
10001bb28:     	tbz	w22, #0x0, 0x10001bb9c <_rig.unordered.Unordered(i64,i64).rehash+0x220>
10001bb2c:     	add	x22, x28, #0x1
10001bb30:     	cmp	x5, x23
10001bb34:     	cinc	x28, x16, ne
10001bb38:     	cmp	x22, x28
10001bb3c:     	b.lo	0x10001bba0 <_rig.unordered.Unordered(i64,i64).rehash+0x224>
10001bb40:     	ldr	d1, [x27]
10001bb44:     	cmeq.8b	v1, v1, #0
10001bb48:     	fmov	x22, d1
10001bb4c:     	ands	x28, x22, x11
10001bb50:     	b.eq	0x10001bbd4 <_rig.unordered.Unordered(i64,i64).rehash+0x258>
10001bb54:     	lsl	x22, x5, #3
10001bb58:     	add	x26, x21, x22
10001bb5c:     	ctz	x27, x28
10001bb60:     	lsr	x27, x27, #3
10001bb64:     	strb	w7, [x26, x27]
10001bb68:     	sub	x5, x22, x5
10001bb6c:     	add	x7, x27, x5
10001bb70:     	mov	x5, #0x2493             ; =9363
10001bb74:     	movk	x5, #0x9249, lsl #16
10001bb78:     	movk	x5, #0x4924, lsl #32
10001bb7c:     	movk	x5, #0x2492, lsl #48
10001bb80:     	umulh	x5, x7, x5
10001bb84:     	sub	x22, x7, x5
10001bb88:     	add	x5, x5, x22, lsr #1
10001bb8c:     	lsr	x5, x5, #2
10001bb90:     	sub	x22, x5, x5, lsl #3
10001bb94:     	add	x26, x22, x7
10001bb98:     	b	0x10001bba4 <_rig.unordered.Unordered(i64,i64).rehash+0x228>
10001bb9c:     	cbz	x30, 0x10001bb40 <_rig.unordered.Unordered(i64,i64).rehash+0x1c4>
10001bba0:     	strb	w7, [x27, x26]
10001bba4:     	madd	x7, x5, x13, x20
10001bba8:     	ldr	q1, [x4, x6]
10001bbac:     	str	q1, [x7, x26, lsl #4]
10001bbb0:     	cmp	x5, x2
10001bbb4:     	csel	x17, x17, x2, eq
10001bbb8:     	csel	x9, x9, x1, eq
10001bbbc:     	sub	x6, x3, #0x1
10001bbc0:     	mov	x2, x5
10001bbc4:     	mov	x1, x26
10001bbc8:     	ands	x3, x6, x3
10001bbcc:     	b.ne	0x10001bac8 <_rig.unordered.Unordered(i64,i64).rehash+0x14c>
10001bbd0:     	b	0x10001ba98 <_rig.unordered.Unordered(i64,i64).rehash+0x11c>
10001bbd4:     	and	x22, x7, #0x7
10001bbd8:     	lsl	w26, w24, w22
10001bbdc:     	mov	w27, #0x1               ; =1
10001bbe0:     	add	x22, x21, x5, lsl #3
10001bbe4:     	ldrb	w28, [x22, #0x7]
10001bbe8:     	orr	w28, w28, w26
10001bbec:     	strb	w28, [x22, #0x7]
10001bbf0:     	add	x5, x5, x27
10001bbf4:     	and	x5, x5, x23
10001bbf8:     	ldr	d1, [x21, x5, lsl #3]
10001bbfc:     	cmeq.8b	v1, v1, #0
10001bc00:     	fmov	x22, d1
10001bc04:     	add	x27, x27, #0x1
10001bc08:     	ands	x28, x22, x11
10001bc0c:     	b.ne	0x10001bb54 <_rig.unordered.Unordered(i64,i64).rehash+0x1d8>
10001bc10:     	b	0x10001bbe0 <_rig.unordered.Unordered(i64,i64).rehash+0x264>
10001bc14:     	ldr	x1, [x19, #0x8]
10001bc18:     	cbz	x1, 0x10001bc38 <_rig.unordered.Unordered(i64,i64).rehash+0x2bc>
10001bc1c:     	ldr	x8, [x19, #0x10]
10001bc20:     	mov	w9, #0x78               ; =120
10001bc24:     	mov	x10, #0x78              ; =120
10001bc28:     	madd	x8, x8, x9, x10
10001bc2c:     	and	x2, x8, #0xfffffffffffffff0
10001bc30:     	mov	w3, #0x3                ; =3
10001bc34:     	bl	0x10002cb44 <_rig.alloc.free>
10001bc38:     	stp	x21, x20, [x19]
10001bc3c:     	strb	w25, [x19, #0x28]
10001bc40:     	lsl	x8, x23, #3
10001bc44:     	sub	x8, x8, x23
10001bc48:     	add	x8, x8, #0x6
10001bc4c:     	lsl	x9, x8, #2
10001bc50:     	mov	x10, #-0x3333333333333334 ; =-3689348814741910324
10001bc54:     	movk	x10, #0xcccd
10001bc58:     	umulh	x9, x9, x10
10001bc5c:     	lsr	x9, x9, #2
10001bc60:     	cmp	x8, #0xe
10001bc64:     	csel	x8, x8, x9, lo
10001bc68:     	stp	x23, x8, [x19, #0x10]
10001bc6c:     	ldp	x29, x30, [sp, #0x50]
10001bc70:     	ldp	x20, x19, [sp, #0x40]
10001bc74:     	ldp	x22, x21, [sp, #0x30]
10001bc78:     	ldp	x24, x23, [sp, #0x20]
10001bc7c:     	ldp	x26, x25, [sp, #0x10]
10001bc80:     	ldp	x28, x27, [sp], #0x60
10001bc84:     	ret
10001bc88:     	bl	0x100004244 <_rig.runtime.oom>

000000010001bc8c <_rig.runtime.FnRef(&.{[]const u8}[0..1],i64).ofFn__func_359.thunk.call>:
10001bc8c:     	mov	x2, x0
10001bc90:     	ldp	x0, x1, [x1]
10001bc94:     	br	x2

000000010001bc98 <___rig_main.one_of>:
10001bc98:     	mov	w0, #0x1                ; =1
10001bc9c:     	ret

000000010001bca0 <___rig_main.int_ensure_with>:
10001bca0:     	sub	sp, sp, #0x80
10001bca4:     	stp	x24, x23, [sp, #0x40]
10001bca8:     	stp	x22, x21, [sp, #0x50]
10001bcac:     	stp	x20, x19, [sp, #0x60]
10001bcb0:     	stp	x29, x30, [sp, #0x70]
10001bcb4:     	mov	x23, #0x101010101010101 ; =72340172838076673
10001bcb8:     	movk	x23, #0x1, lsl #48
10001bcbc:     	adrp	x8, 0x10003c000 <dyld_stub_binder+0x10003c000>
10001bcc0:     	add	x8, x8, #0x340
10001bcc4:     	ldr	q0, [x8]
10001bcc8:     	str	q0, [sp]
10001bccc:     	mov	w9, #0x3f               ; =63
10001bcd0:     	str	x9, [sp, #0x30]
10001bcd4:     	ldr	q0, [x8, #0x20]
10001bcd8:     	str	q0, [sp, #0x20]
10001bcdc:     	mov	w8, #0x1                ; =1
10001bce0:     	stp	xzr, x8, [sp, #0x10]
10001bce4:     	mov	x0, sp
10001bce8:     	bl	0x10001c060 <___rig_main.int_ensure_with_pass>
10001bcec:     	mov	x19, x0
10001bcf0:     	ldr	x20, [sp]
10001bcf4:     	adrp	x0, 0x100031000 <___anon_5843+0x8>
10001bcf8:     	add	x0, x0, #0xaa
10001bcfc:     	bl	0x1000186e8 <_rig.runtime.outFixed__func_48>
10001bd00:     	mov	x0, x19
10001bd04:     	bl	0x10002c2d8 <_rig.runtime.outValueOf__func_25>
10001bd08:     	bl	0x100018694 <_rig.runtime.outFixed__func_49>
10001bd0c:     	mov	x0, x20
10001bd10:     	bl	0x10002c2d8 <_rig.runtime.outValueOf__func_25>
10001bd14:     	bl	0x10002c230 <_rig.runtime.outFixed__func_26>
10001bd18:     	mov	x0, sp
10001bd1c:     	bl	0x10001c060 <___rig_main.int_ensure_with_pass>
10001bd20:     	mov	x20, x0
10001bd24:     	ldp	x8, x19, [sp, #0x8]
10001bd28:     	ldr	d0, [x8]
10001bd2c:     	movi.8b	v1, #0x8
10001bd30:     	cmeq.8b	v0, v0, v1
10001bd34:     	fmov	x9, d0
10001bd38:     	ands	x9, x9, x23
10001bd3c:     	b.eq	0x10001bd7c <___rig_main.int_ensure_with+0xdc>
10001bd40:     	prfm	pldl1keep, [x19]
10001bd44:     	ctz	x10, x9
10001bd48:     	add	x10, x19, x10, lsl #1
10001bd4c:     	ldr	x11, [x10]
10001bd50:     	cbnz	x11, 0x10001bd70 <___rig_main.int_ensure_with+0xd0>
10001bd54:     	ldr	x22, [x10, #0x8]
10001bd58:     	mov	w21, #0x1               ; =1
10001bd5c:     	b	0x10001bd88 <___rig_main.int_ensure_with+0xe8>
10001bd60:     	ctz	x10, x9
10001bd64:     	lsl	x10, x10, #1
10001bd68:     	ldr	x11, [x19, x10]
10001bd6c:     	cbz	x11, 0x10001be7c <___rig_main.int_ensure_with+0x1dc>
10001bd70:     	sub	x10, x9, #0x1
10001bd74:     	ands	x9, x10, x9
10001bd78:     	b.ne	0x10001bd60 <___rig_main.int_ensure_with+0xc0>
