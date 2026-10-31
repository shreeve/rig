
/private/tmp/claude-501/-Users-shreeve-Data-Claude-Worktrees-rig-incredible-project-25d019/61e6bc21-7c82-43f3-8978-0dbbd8206817/scratchpad/s2/full/p-0xWW4b33-0.bin:	file format mach-o arm64

Disassembly of section __TEXT,__text:

000000010001c7fc <_rig.unordered.Unordered(i64,i64).rehash>:
10001c7fc:     	sub	sp, sp, #0x70
10001c800:     	stp	x28, x27, [sp, #0x10]
10001c804:     	stp	x26, x25, [sp, #0x20]
10001c808:     	stp	x24, x23, [sp, #0x30]
10001c80c:     	stp	x22, x21, [sp, #0x40]
10001c810:     	stp	x20, x19, [sp, #0x50]
10001c814:     	stp	x29, x30, [sp, #0x60]
10001c818:     	mov	x19, x0
10001c81c:     	mov	x8, #0x2493             ; =9363
10001c820:     	movk	x8, #0x9249, lsl #16
10001c824:     	movk	x8, #0x4924, lsl #32
10001c828:     	movk	x8, #0x2492, lsl #48
10001c82c:     	umulh	x8, x1, x8
10001c830:     	sub	x9, x1, x8
10001c834:     	add	x8, x8, x9, lsr #1
10001c838:     	lsr	x8, x8, #2
10001c83c:     	umax	x8, x8, #0x3
10001c840:     	clz	x23, x8
10001c844:     	mov	w24, #0x40              ; =64
10001c848:     	sub	w21, w24, w23
10001c84c:     	mov	w8, #0x78               ; =120
10001c850:     	lsl	x8, x8, x21
10001c854:     	and	x1, x8, #0xfffffffffffffff0
10001c858:     	mov	w2, #0x3                ; =3
10001c85c:     	bl	0x10002dbf0 <_rig.alloc.alloc>
10001c860:     	cbz	x0, 0x10001cd0c <_rig.unordered.Unordered(i64,i64).rehash+0x510>
10001c864:     	mov	x20, x0
10001c868:     	and	x8, x21, #0xffff
10001c86c:     	mov	w26, #0x1               ; =1
10001c870:     	lsl	x9, x26, x8
10001c874:     	tst	x8, #0x40
10001c878:     	csel	x25, xzr, x9, ne
10001c87c:     	mov	w9, #0x70               ; =112
10001c880:     	lsl	x8, x9, x8
10001c884:     	add	x8, x0, x8
10001c888:     	sub	x8, x8, #0x10
10001c88c:     	neg	w9, w8
10001c890:     	and	x9, x9, #0x7
10001c894:     	add	x21, x9, x8
10001c898:     	lsl	x1, x25, #3
10001c89c:     	mov	x0, x21
10001c8a0:     	bl	0x10002fecc <dyld_stub_binder+0x10002fecc>
10001c8a4:     	sub	x22, x25, #0x1
10001c8a8:     	add	x8, x21, x22, lsl #3
10001c8ac:     	strb	w26, [x8, #0x6]
10001c8b0:     	neg	w8, w23
10001c8b4:     	and	w8, w8, #0x3f
10001c8b8:     	sub	w23, w24, w8
10001c8bc:     	ldr	x8, [x19, #0x8]
10001c8c0:     	cbz	x8, 0x10001ccb8 <_rig.unordered.Unordered(i64,i64).rehash+0x4bc>
10001c8c4:     	ldr	x9, [x19, #0x10]
10001c8c8:     	lsl	x10, x9, #1
10001c8cc:     	add	x10, x10, #0x2
10001c8d0:     	cmp	x10, x25
10001c8d4:     	b.ne	0x10001cb94 <_rig.unordered.Unordered(i64,i64).rehash+0x398>
10001c8d8:     	mov	x11, #0x0               ; =0
10001c8dc:     	mov	x10, #0xd4a3            ; =54435
10001c8e0:     	movk	x10, #0xd433, lsl #16
10001c8e4:     	movk	x10, #0xa62e, lsl #32
10001c8e8:     	movk	x10, #0x4b33, lsl #48
10001c8ec:     	mov	x12, #0x101010101010101 ; =72340172838076673
10001c8f0:     	movk	x12, #0x1, lsl #48
10001c8f4:     	movi.8b	v0, #0x1
10001c8f8:     	mov	w13, #0x1               ; =1
10001c8fc:     	adrp	x14, 0x100030000 <dyld_stub_binder+0x100030000>
10001c900:     	ldr	d1, [x14, #0x8e8]
10001c904:     	movi.2d	v2, #0x000000000000ff
10001c908:     	mov	w14, #0x70              ; =112
10001c90c:     	mov	w15, #0x6               ; =6
10001c910:     	mov	x16, sp
10001c914:     	adrp	x17, 0x100031000 <dyld_stub_binder+0x100031000>
10001c918:     	add	x17, x17, #0x86b
10001c91c:     	b	0x10001c92c <_rig.unordered.Unordered(i64,i64).rehash+0x130>
10001c920:     	cmp	x11, x9
10001c924:     	add	x11, x11, #0x1
10001c928:     	b.eq	0x10001cc94 <_rig.unordered.Unordered(i64,i64).rehash+0x498>
10001c92c:     	ldr	x0, [x19]
10001c930:     	ldr	d3, [x0, x11, lsl #3]
10001c934:     	cmhi.8b	v3, v3, v0
10001c938:     	fmov	x0, d3
10001c93c:     	ands	x1, x0, x12
10001c940:     	b.eq	0x10001c920 <_rig.unordered.Unordered(i64,i64).rehash+0x124>
10001c944:     	mov	x0, #0x0                ; =0
10001c948:     	add	x2, x21, x11, lsl #4
10001c94c:     	orr	x3, x13, x11, lsl #1
10001c950:     	ldr	d4, [x2]
10001c954:     	ldr	d3, [x21, x3, lsl #3]
10001c958:     	umov.b	w4, v4[2]
10001c95c:     	umov.b	w5, v4[3]
10001c960:     	umov.b	w7, v4[4]
10001c964:     	umov.b	w25, v4[5]
10001c968:     	umov.b	w6, v3[2]
10001c96c:     	umov.b	w24, v3[3]
10001c970:     	umov.b	w26, v3[4]
10001c974:     	umov.b	w27, v3[5]
10001c978:     	dup.4h	v5, v3[3]
10001c97c:     	fmov	x28, d5
10001c980:     	mov	b5, v4[0]
10001c984:     	mov.b	v5[4], v4[1]
10001c988:     	cmhi.8b	v6, v4, v0
10001c98c:     	mov.d	v4[1], v4[0]
10001c990:     	tbl.8b	v4, { v4 }, v1
10001c994:     	ubfiz	w27, w27, #8, #8
10001c998:     	orr	w27, w27, w28, lsl #16
10001c99c:     	fmov	x28, d4
10001c9a0:     	ubfiz	x25, x25, #8, #8
10001c9a4:     	orr	x25, x25, x28, lsl #16
10001c9a8:     	bfxil	w27, w26, #0, #8
10001c9ac:     	bfxil	x25, x7, #0, #8
10001c9b0:     	ubfiz	x7, x24, #8, #8
10001c9b4:     	ubfiz	x5, x5, #8, #8
10001c9b8:     	orr	x7, x7, x27, lsl #16
10001c9bc:     	orr	x5, x5, x25, lsl #16
10001c9c0:     	bfxil	x7, x6, #0, #8
10001c9c4:     	bfxil	x5, x4, #0, #8
10001c9c8:     	mov	b4, v3[0]
10001c9cc:     	mov.b	v4[4], v3[1]
10001c9d0:     	zip2.2s	v7, v5, v4
10001c9d4:     	ushll.2d	v7, v7, #0x0
10001c9d8:     	and.16b	v7, v7, v2
10001c9dc:     	zip1.2s	v4, v5, v4
10001c9e0:     	ushll.2d	v4, v4, #0x0
10001c9e4:     	and.16b	v4, v4, v2
10001c9e8:     	fmov	d5, x5
10001c9ec:     	mov.d	v5[1], x7
10001c9f0:     	shl.2d	v5, v5, #0x10
10001c9f4:     	shl.2d	v7, v7, #0x8
10001c9f8:     	orr.16b	v4, v7, v4
10001c9fc:     	orr.16b	v4, v5, v4
10001ca00:     	fmov	x4, d6
10001ca04:     	and	x4, x4, x12
10001ca08:     	cnt	x5, x4
10001ca0c:     	cmhi.8b	v3, v3, v0
10001ca10:     	fmov	x4, d3
10001ca14:     	and	x4, x4, x12
10001ca18:     	cnt	x6, x4
10001ca1c:     	madd	x4, x11, x14, x8
10001ca20:     	cmp	x3, x22
10001ca24:     	cset	w7, eq
10001ca28:     	ctz	x24, x1
10001ca2c:     	lsl	x24, x24, #1
10001ca30:     	and	x24, x24, #0xf0
10001ca34:     	ldr	x25, [x4, x24]
10001ca38:     	mul	x25, x25, x10
10001ca3c:     	ror	x25, x25, #0x38
10001ca40:     	lsr	x26, x25, x23
10001ca44:     	and	x25, x25, #0xff
10001ca48:     	ldrb	w25, [x17, x25]
10001ca4c:     	tst	x26, #0x1
10001ca50:     	cset	w27, eq
10001ca54:     	csel	x28, x6, x5, ne
10001ca58:     	tst	w7, w26
10001ca5c:     	cinc	x7, x15, eq
10001ca60:     	cmp	x11, x26, lsr #1
10001ca64:     	cset	w30, eq
10001ca68:     	cmp	x28, x7
10001ca6c:     	cset	w7, lo
10001ca70:     	ands	w7, w30, w7
10001ca74:     	csel	x25, x25, xzr, ne
10001ca78:     	lsl	x30, x28, #3
10001ca7c:     	lsl	x25, x25, x30
10001ca80:     	dup.2s	v3, w26
10001ca84:     	ushll.2d	v3, v3, #0x0
10001ca88:     	shl.2d	v3, v3, #0x3f
10001ca8c:     	cmlt.2d	v3, v3, #0
10001ca90:     	movi.2d	v5, #0000000000000000
10001ca94:     	mov.d	v5[1], x25
10001ca98:     	movi.2d	v6, #0000000000000000
10001ca9c:     	mov.d	v6[0], x25
10001caa0:     	bsl.16b	v3, v5, v6
10001caa4:     	orr.16b	v4, v3, v4
10001caa8:     	and	w25, w7, w27
10001caac:     	add	x5, x5, x25
10001cab0:     	and	w7, w26, w7
10001cab4:     	add	x6, x6, x7
10001cab8:     	madd	x7, x26, x14, x20
10001cabc:     	add	x7, x7, x28, lsl #4
10001cac0:     	csel	x7, x7, x16, ne
10001cac4:     	ldr	q3, [x4, x24]
10001cac8:     	str	q3, [x7]
10001cacc:     	neg	x7, x1
10001cad0:     	and	x7, x1, x7
10001cad4:     	csel	x7, xzr, x7, ne
10001cad8:     	orr	x0, x7, x0
10001cadc:     	sub	x7, x1, #0x1
10001cae0:     	ands	x1, x7, x1
10001cae4:     	b.ne	0x10001ca20 <_rig.unordered.Unordered(i64,i64).rehash+0x224>
10001cae8:     	str	q4, [x2]
10001caec:     	cbz	x0, 0x10001c920 <_rig.unordered.Unordered(i64,i64).rehash+0x124>
10001caf0:     	ctz	x1, x0
10001caf4:     	lsl	x1, x1, #1
10001caf8:     	and	x1, x1, #0xf0
10001cafc:     	ldr	x2, [x4, x1]
10001cb00:     	mul	x2, x2, x10
10001cb04:     	ror	x3, x2, #0x38
10001cb08:     	and	x2, x3, #0xff
10001cb0c:     	ldrb	w2, [x17, x2]
10001cb10:     	lsr	x3, x3, x23
10001cb14:     	ldr	d3, [x21, x3, lsl #3]
10001cb18:     	cmeq.8b	v3, v3, #0
10001cb1c:     	fmov	x5, d3
10001cb20:     	ands	x7, x5, x12
10001cb24:     	b.eq	0x10001cb54 <_rig.unordered.Unordered(i64,i64).rehash+0x358>
10001cb28:     	add	x5, x21, x3, lsl #3
10001cb2c:     	ctz	x6, x7
10001cb30:     	lsr	x6, x6, #3
10001cb34:     	strb	w2, [x5, x6]
10001cb38:     	madd	x2, x3, x14, x20
10001cb3c:     	ldr	q3, [x4, x1]
10001cb40:     	str	q3, [x2, x6, lsl #4]
10001cb44:     	sub	x1, x0, #0x1
10001cb48:     	ands	x0, x1, x0
10001cb4c:     	b.ne	0x10001caf0 <_rig.unordered.Unordered(i64,i64).rehash+0x2f4>
10001cb50:     	b	0x10001c920 <_rig.unordered.Unordered(i64,i64).rehash+0x124>
10001cb54:     	and	x5, x2, #0x7
10001cb58:     	lsl	w5, w13, w5
10001cb5c:     	mov	w6, #0x1                ; =1
10001cb60:     	add	x7, x21, x3, lsl #3
10001cb64:     	ldrb	w24, [x7, #0x7]
10001cb68:     	orr	w24, w24, w5
10001cb6c:     	strb	w24, [x7, #0x7]
10001cb70:     	add	x3, x3, x6
10001cb74:     	and	x3, x3, x22
10001cb78:     	ldr	d3, [x21, x3, lsl #3]
10001cb7c:     	cmeq.8b	v3, v3, #0
10001cb80:     	fmov	x7, d3
10001cb84:     	add	x6, x6, #0x1
10001cb88:     	ands	x7, x7, x12
10001cb8c:     	b.ne	0x10001cb28 <_rig.unordered.Unordered(i64,i64).rehash+0x32c>
10001cb90:     	b	0x10001cb60 <_rig.unordered.Unordered(i64,i64).rehash+0x364>
10001cb94:     	mov	x11, #0x0               ; =0
10001cb98:     	mov	x10, #0xd4a3            ; =54435
10001cb9c:     	movk	x10, #0xd433, lsl #16
10001cba0:     	movk	x10, #0xa62e, lsl #32
10001cba4:     	movk	x10, #0x4b33, lsl #48
10001cba8:     	mov	x12, #0x101010101010101 ; =72340172838076673
10001cbac:     	movk	x12, #0x1, lsl #48
10001cbb0:     	movi.8b	v0, #0x1
10001cbb4:     	mov	w13, #0x70              ; =112
10001cbb8:     	mov	w14, #0x1               ; =1
10001cbbc:     	adrp	x15, 0x100031000 <dyld_stub_binder+0x100031000>
10001cbc0:     	add	x15, x15, #0x86b
10001cbc4:     	b	0x10001cbd4 <_rig.unordered.Unordered(i64,i64).rehash+0x3d8>
10001cbc8:     	cmp	x11, x9
10001cbcc:     	add	x11, x11, #0x1
10001cbd0:     	b.eq	0x10001cc94 <_rig.unordered.Unordered(i64,i64).rehash+0x498>
10001cbd4:     	ldr	x16, [x19]
10001cbd8:     	ldr	d1, [x16, x11, lsl #3]
10001cbdc:     	cmhi.8b	v1, v1, v0
10001cbe0:     	fmov	x16, d1
10001cbe4:     	ands	x16, x16, x12
10001cbe8:     	b.eq	0x10001cbc8 <_rig.unordered.Unordered(i64,i64).rehash+0x3cc>
10001cbec:     	madd	x17, x11, x13, x8
10001cbf0:     	ctz	x0, x16
10001cbf4:     	lsl	x0, x0, #1
10001cbf8:     	and	x0, x0, #0xf0
10001cbfc:     	ldr	x1, [x17, x0]
10001cc00:     	mul	x1, x1, x10
10001cc04:     	ror	x2, x1, #0x38
10001cc08:     	and	x1, x2, #0xff
10001cc0c:     	ldrb	w1, [x15, x1]
10001cc10:     	lsr	x2, x2, x23
10001cc14:     	ldr	d1, [x21, x2, lsl #3]
10001cc18:     	cmeq.8b	v1, v1, #0
10001cc1c:     	fmov	x3, d1
10001cc20:     	ands	x5, x3, x12
10001cc24:     	b.eq	0x10001cc54 <_rig.unordered.Unordered(i64,i64).rehash+0x458>
10001cc28:     	add	x3, x21, x2, lsl #3
10001cc2c:     	ctz	x4, x5
10001cc30:     	lsr	x4, x4, #3
10001cc34:     	strb	w1, [x3, x4]
10001cc38:     	madd	x1, x2, x13, x20
10001cc3c:     	ldr	q1, [x17, x0]
10001cc40:     	str	q1, [x1, x4, lsl #4]
10001cc44:     	sub	x0, x16, #0x1
10001cc48:     	ands	x16, x0, x16
10001cc4c:     	b.ne	0x10001cbf0 <_rig.unordered.Unordered(i64,i64).rehash+0x3f4>
10001cc50:     	b	0x10001cbc8 <_rig.unordered.Unordered(i64,i64).rehash+0x3cc>
10001cc54:     	and	x3, x1, #0x7
10001cc58:     	lsl	w3, w14, w3
10001cc5c:     	mov	w4, #0x1                ; =1
10001cc60:     	add	x5, x21, x2, lsl #3
10001cc64:     	ldrb	w6, [x5, #0x7]
10001cc68:     	orr	w6, w6, w3
10001cc6c:     	strb	w6, [x5, #0x7]
10001cc70:     	add	x2, x2, x4
10001cc74:     	and	x2, x2, x22
10001cc78:     	ldr	d1, [x21, x2, lsl #3]
10001cc7c:     	cmeq.8b	v1, v1, #0
10001cc80:     	fmov	x5, d1
10001cc84:     	add	x4, x4, #0x1
10001cc88:     	ands	x5, x5, x12
10001cc8c:     	b.ne	0x10001cc28 <_rig.unordered.Unordered(i64,i64).rehash+0x42c>
10001cc90:     	b	0x10001cc60 <_rig.unordered.Unordered(i64,i64).rehash+0x464>
10001cc94:     	ldr	x1, [x19, #0x8]
10001cc98:     	cbz	x1, 0x10001ccb8 <_rig.unordered.Unordered(i64,i64).rehash+0x4bc>
10001cc9c:     	ldr	x8, [x19, #0x10]
10001cca0:     	mov	w9, #0x78               ; =120
10001cca4:     	mov	x10, #0x78              ; =120
10001cca8:     	madd	x8, x8, x9, x10
10001ccac:     	and	x2, x8, #0xfffffffffffffff0
10001ccb0:     	mov	w3, #0x3                ; =3
10001ccb4:     	bl	0x10002dc60 <_rig.alloc.free>
10001ccb8:     	stp	x21, x20, [x19]
10001ccbc:     	strb	w23, [x19, #0x28]
10001ccc0:     	lsl	x8, x22, #3
10001ccc4:     	sub	x8, x8, x22
10001ccc8:     	add	x8, x8, #0x6
10001cccc:     	lsl	x9, x8, #2
10001ccd0:     	mov	x10, #-0x3333333333333334 ; =-3689348814741910324
10001ccd4:     	movk	x10, #0xcccd
10001ccd8:     	umulh	x9, x9, x10
10001ccdc:     	lsr	x9, x9, #2
10001cce0:     	cmp	x8, #0xe
10001cce4:     	csel	x8, x8, x9, lo
10001cce8:     	stp	x22, x8, [x19, #0x10]
10001ccec:     	ldp	x29, x30, [sp, #0x60]
10001ccf0:     	ldp	x20, x19, [sp, #0x50]
10001ccf4:     	ldp	x22, x21, [sp, #0x40]
10001ccf8:     	ldp	x24, x23, [sp, #0x30]
