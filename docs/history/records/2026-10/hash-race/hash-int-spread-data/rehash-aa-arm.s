
/private/tmp/claude-501/-Users-shreeve-Data-Claude-Worktrees-rig-incredible-project-25d019/61e6bc21-7c82-43f3-8978-0dbbd8206817/scratchpad/s2/full/p-0xAA4b33-0.bin:	file format mach-o arm64

Disassembly of section __TEXT,__text:

000000010001c178 <_rig.unordered.Unordered(i64,i64).rehash>:
10001c178:     	stp	x28, x27, [sp, #-0x60]!
10001c17c:     	stp	x26, x25, [sp, #0x10]
10001c180:     	stp	x24, x23, [sp, #0x20]
10001c184:     	stp	x22, x21, [sp, #0x30]
10001c188:     	stp	x20, x19, [sp, #0x40]
10001c18c:     	stp	x29, x30, [sp, #0x50]
10001c190:     	mov	x19, x0
10001c194:     	mov	x24, #0x2493            ; =9363
10001c198:     	movk	x24, #0x9249, lsl #16
10001c19c:     	movk	x24, #0x4924, lsl #32
10001c1a0:     	movk	x24, #0x2492, lsl #48
10001c1a4:     	umulh	x8, x1, x24
10001c1a8:     	sub	x9, x1, x8
10001c1ac:     	add	x8, x8, x9, lsr #1
10001c1b0:     	lsr	x8, x8, #2
10001c1b4:     	umax	x8, x8, #0x3
10001c1b8:     	clz	x23, x8
10001c1bc:     	mov	w25, #0x40              ; =64
10001c1c0:     	sub	w21, w25, w23
10001c1c4:     	mov	w8, #0x78               ; =120
10001c1c8:     	lsl	x8, x8, x21
10001c1cc:     	and	x1, x8, #0xfffffffffffffff0
10001c1d0:     	mov	w2, #0x3                ; =3
10001c1d4:     	bl	0x10002d0fc <_rig.alloc.alloc>
10001c1d8:     	cbz	x0, 0x10001c570 <_rig.unordered.Unordered(i64,i64).rehash+0x3f8>
10001c1dc:     	mov	x20, x0
10001c1e0:     	and	x8, x21, #0xffff
10001c1e4:     	mov	w27, #0x1               ; =1
10001c1e8:     	lsl	x9, x27, x8
10001c1ec:     	tst	x8, #0x40
10001c1f0:     	csel	x26, xzr, x9, ne
10001c1f4:     	mov	w9, #0x70               ; =112
10001c1f8:     	lsl	x8, x9, x8
10001c1fc:     	add	x8, x0, x8
10001c200:     	sub	x8, x8, #0x10
10001c204:     	neg	w9, w8
10001c208:     	and	x9, x9, #0x7
10001c20c:     	add	x21, x9, x8
10001c210:     	lsl	x1, x26, #3
10001c214:     	mov	x0, x21
10001c218:     	bl	0x10002f3d8 <dyld_stub_binder+0x10002f3d8>
10001c21c:     	sub	x22, x26, #0x1
10001c220:     	add	x8, x21, x22, lsl #3
10001c224:     	strb	w27, [x8, #0x6]
10001c228:     	neg	w8, w23
10001c22c:     	and	w8, w8, #0x3f
10001c230:     	sub	w23, w25, w8
10001c234:     	ldr	x8, [x19, #0x8]
10001c238:     	cbz	x8, 0x10001c520 <_rig.unordered.Unordered(i64,i64).rehash+0x3a8>
10001c23c:     	ldr	x9, [x19, #0x10]
10001c240:     	lsl	x10, x9, #1
10001c244:     	add	x10, x10, #0x2
10001c248:     	cmp	x10, x26
10001c24c:     	b.ne	0x10001c3fc <_rig.unordered.Unordered(i64,i64).rehash+0x284>
10001c250:     	mov	x11, #0x0               ; =0
10001c254:     	mov	x10, #0xd4a3            ; =54435
10001c258:     	movk	x10, #0xd433, lsl #16
10001c25c:     	movk	x10, #0xa62e, lsl #32
10001c260:     	movk	x10, #0x4b33, lsl #48
10001c264:     	mov	x12, #0x101010101010101 ; =72340172838076673
10001c268:     	movk	x12, #0x1, lsl #48
10001c26c:     	movi.8b	v0, #0x1
10001c270:     	mov	w13, #0x1               ; =1
10001c274:     	mov	w14, #0x70              ; =112
10001c278:     	mov	w15, #0x6               ; =6
10001c27c:     	adrp	x16, 0x100030000 <dyld_stub_binder+0x100030000>
10001c280:     	add	x16, x16, #0xd7b
10001c284:     	b	0x10001c294 <_rig.unordered.Unordered(i64,i64).rehash+0x11c>
10001c288:     	cmp	x11, x9
10001c28c:     	add	x11, x11, #0x1
10001c290:     	b.eq	0x10001c4fc <_rig.unordered.Unordered(i64,i64).rehash+0x384>
10001c294:     	ldr	x17, [x19]
10001c298:     	ldr	d1, [x17, x11, lsl #3]
10001c29c:     	cmhi.8b	v1, v1, v0
10001c2a0:     	fmov	x17, d1
10001c2a4:     	ands	x17, x17, x12
10001c2a8:     	b.eq	0x10001c288 <_rig.unordered.Unordered(i64,i64).rehash+0x110>
10001c2ac:     	lsl	x0, x11, #1
10001c2b0:     	lsl	x1, x11, #4
10001c2b4:     	ldr	d1, [x21, x1]
10001c2b8:     	cmhi.8b	v1, v1, v0
10001c2bc:     	fmov	x1, d1
10001c2c0:     	and	x2, x1, x12
10001c2c4:     	mov	w1, #0x1                ; =1
10001c2c8:     	bfi	x1, x11, #1, #63
10001c2cc:     	ldr	d1, [x21, x1, lsl #3]
10001c2d0:     	cnt	x2, x2
10001c2d4:     	cmhi.8b	v1, v1, v0
10001c2d8:     	fmov	x3, d1
10001c2dc:     	and	x3, x3, x12
10001c2e0:     	cnt	x3, x3
10001c2e4:     	madd	x4, x11, x14, x8
10001c2e8:     	cmp	x1, x22
10001c2ec:     	ctz	x5, x17
10001c2f0:     	lsl	x5, x5, #1
10001c2f4:     	and	x5, x5, #0xf0
10001c2f8:     	ldr	x6, [x4, x5]
10001c2fc:     	mul	x6, x6, x10
10001c300:     	ror	x7, x6, #0x38
10001c304:     	cset	w26, eq
10001c308:     	lsr	x6, x7, x23
10001c30c:     	ands	x25, x6, #0x1
10001c310:     	csel	x27, x3, x2, ne
10001c314:     	tst	w26, w6
10001c318:     	cinc	x26, x15, eq
10001c31c:     	and	x7, x7, #0xff
10001c320:     	ldrb	w7, [x16, x7]
10001c324:     	add	x28, x21, x6, lsl #3
10001c328:     	cmp	x11, x6, lsr #1
10001c32c:     	ccmp	x27, x26, #0x2, eq
10001c330:     	b.hs	0x10001c368 <_rig.unordered.Unordered(i64,i64).rehash+0x1f0>
10001c334:     	cmp	x25, #0x0
10001c338:     	cset	w26, eq
10001c33c:     	strb	w7, [x28, x27]
10001c340:     	sub	x7, x27, x6
10001c344:     	add	x6, x7, x6, lsl #3
10001c348:     	add	x3, x25, x3
10001c34c:     	add	x2, x2, w26, uxtw
10001c350:     	ldr	q1, [x4, x5]
10001c354:     	str	q1, [x20, x6, lsl #4]
10001c358:     	sub	x5, x17, #0x1
10001c35c:     	ands	x17, x5, x17
10001c360:     	b.ne	0x10001c2e8 <_rig.unordered.Unordered(i64,i64).rehash+0x170>
10001c364:     	b	0x10001c288 <_rig.unordered.Unordered(i64,i64).rehash+0x110>
10001c368:     	ldr	d1, [x28]
10001c36c:     	cmeq.8b	v1, v1, #0
10001c370:     	fmov	x25, d1
10001c374:     	ands	x27, x25, x12
10001c378:     	b.eq	0x10001c3bc <_rig.unordered.Unordered(i64,i64).rehash+0x244>
10001c37c:     	lsl	x25, x6, #3
10001c380:     	add	x26, x21, x25
10001c384:     	ctz	x27, x27
10001c388:     	lsr	x27, x27, #3
10001c38c:     	strb	w7, [x26, x27]
10001c390:     	sub	x6, x25, x6
10001c394:     	add	x6, x27, x6
10001c398:     	umulh	x7, x6, x24
10001c39c:     	sub	x25, x6, x7
10001c3a0:     	add	x7, x7, x25, lsr #1
10001c3a4:     	lsr	x7, x7, #2
10001c3a8:     	cmp	x7, x0
10001c3ac:     	cset	w26, eq
10001c3b0:     	cmp	x7, x1
10001c3b4:     	cset	w25, eq
10001c3b8:     	b	0x10001c348 <_rig.unordered.Unordered(i64,i64).rehash+0x1d0>
10001c3bc:     	and	x25, x7, #0x7
10001c3c0:     	lsl	w25, w13, w25
10001c3c4:     	mov	w26, #0x1               ; =1
10001c3c8:     	add	x27, x21, x6, lsl #3
10001c3cc:     	ldrb	w28, [x27, #0x7]
10001c3d0:     	orr	w28, w28, w25
10001c3d4:     	strb	w28, [x27, #0x7]
10001c3d8:     	add	x6, x6, x26
10001c3dc:     	and	x6, x6, x22
10001c3e0:     	ldr	d1, [x21, x6, lsl #3]
10001c3e4:     	cmeq.8b	v1, v1, #0
10001c3e8:     	fmov	x27, d1
10001c3ec:     	add	x26, x26, #0x1
10001c3f0:     	ands	x27, x27, x12
10001c3f4:     	b.ne	0x10001c37c <_rig.unordered.Unordered(i64,i64).rehash+0x204>
10001c3f8:     	b	0x10001c3c8 <_rig.unordered.Unordered(i64,i64).rehash+0x250>
10001c3fc:     	mov	x11, #0x0               ; =0
10001c400:     	mov	x10, #0xd4a3            ; =54435
10001c404:     	movk	x10, #0xd433, lsl #16
10001c408:     	movk	x10, #0xa62e, lsl #32
10001c40c:     	movk	x10, #0x4b33, lsl #48
10001c410:     	mov	x12, #0x101010101010101 ; =72340172838076673
10001c414:     	movk	x12, #0x1, lsl #48
10001c418:     	movi.8b	v0, #0x1
10001c41c:     	mov	w13, #0x70              ; =112
10001c420:     	mov	w14, #0x1               ; =1
10001c424:     	adrp	x15, 0x100030000 <dyld_stub_binder+0x100030000>
10001c428:     	add	x15, x15, #0xd7b
10001c42c:     	b	0x10001c43c <_rig.unordered.Unordered(i64,i64).rehash+0x2c4>
10001c430:     	cmp	x11, x9
10001c434:     	add	x11, x11, #0x1
10001c438:     	b.eq	0x10001c4fc <_rig.unordered.Unordered(i64,i64).rehash+0x384>
10001c43c:     	ldr	x16, [x19]
10001c440:     	ldr	d1, [x16, x11, lsl #3]
10001c444:     	cmhi.8b	v1, v1, v0
10001c448:     	fmov	x16, d1
10001c44c:     	ands	x16, x16, x12
10001c450:     	b.eq	0x10001c430 <_rig.unordered.Unordered(i64,i64).rehash+0x2b8>
10001c454:     	madd	x17, x11, x13, x8
10001c458:     	ctz	x0, x16
10001c45c:     	lsl	x0, x0, #1
10001c460:     	and	x0, x0, #0xf0
10001c464:     	ldr	x1, [x17, x0]
10001c468:     	mul	x1, x1, x10
10001c46c:     	ror	x2, x1, #0x38
10001c470:     	and	x1, x2, #0xff
10001c474:     	ldrb	w1, [x15, x1]
10001c478:     	lsr	x2, x2, x23
10001c47c:     	ldr	d1, [x21, x2, lsl #3]
10001c480:     	cmeq.8b	v1, v1, #0
10001c484:     	fmov	x3, d1
10001c488:     	ands	x5, x3, x12
10001c48c:     	b.eq	0x10001c4bc <_rig.unordered.Unordered(i64,i64).rehash+0x344>
10001c490:     	add	x3, x21, x2, lsl #3
10001c494:     	ctz	x4, x5
10001c498:     	lsr	x4, x4, #3
10001c49c:     	strb	w1, [x3, x4]
10001c4a0:     	madd	x1, x2, x13, x20
10001c4a4:     	ldr	q1, [x17, x0]
10001c4a8:     	str	q1, [x1, x4, lsl #4]
10001c4ac:     	sub	x0, x16, #0x1
10001c4b0:     	ands	x16, x0, x16
10001c4b4:     	b.ne	0x10001c458 <_rig.unordered.Unordered(i64,i64).rehash+0x2e0>
10001c4b8:     	b	0x10001c430 <_rig.unordered.Unordered(i64,i64).rehash+0x2b8>
10001c4bc:     	and	x3, x1, #0x7
10001c4c0:     	lsl	w3, w14, w3
10001c4c4:     	mov	w4, #0x1                ; =1
10001c4c8:     	add	x5, x21, x2, lsl #3
10001c4cc:     	ldrb	w6, [x5, #0x7]
10001c4d0:     	orr	w6, w6, w3
10001c4d4:     	strb	w6, [x5, #0x7]
10001c4d8:     	add	x2, x2, x4
10001c4dc:     	and	x2, x2, x22
10001c4e0:     	ldr	d1, [x21, x2, lsl #3]
10001c4e4:     	cmeq.8b	v1, v1, #0
10001c4e8:     	fmov	x5, d1
10001c4ec:     	add	x4, x4, #0x1
10001c4f0:     	ands	x5, x5, x12
10001c4f4:     	b.ne	0x10001c490 <_rig.unordered.Unordered(i64,i64).rehash+0x318>
10001c4f8:     	b	0x10001c4c8 <_rig.unordered.Unordered(i64,i64).rehash+0x350>
10001c4fc:     	ldr	x1, [x19, #0x8]
10001c500:     	cbz	x1, 0x10001c520 <_rig.unordered.Unordered(i64,i64).rehash+0x3a8>
10001c504:     	ldr	x8, [x19, #0x10]
10001c508:     	mov	w9, #0x78               ; =120
10001c50c:     	mov	x10, #0x78              ; =120
10001c510:     	madd	x8, x8, x9, x10
10001c514:     	and	x2, x8, #0xfffffffffffffff0
10001c518:     	mov	w3, #0x3                ; =3
10001c51c:     	bl	0x10002d16c <_rig.alloc.free>
10001c520:     	stp	x21, x20, [x19]
10001c524:     	strb	w23, [x19, #0x28]
10001c528:     	lsl	x8, x22, #3
10001c52c:     	sub	x8, x8, x22
10001c530:     	add	x8, x8, #0x6
10001c534:     	lsl	x9, x8, #2
10001c538:     	mov	x10, #-0x3333333333333334 ; =-3689348814741910324
10001c53c:     	movk	x10, #0xcccd
10001c540:     	umulh	x9, x9, x10
10001c544:     	lsr	x9, x9, #2
10001c548:     	cmp	x8, #0xe
10001c54c:     	csel	x8, x8, x9, lo
10001c550:     	stp	x22, x8, [x19, #0x10]
10001c554:     	ldp	x29, x30, [sp, #0x50]
10001c558:     	ldp	x20, x19, [sp, #0x40]
10001c55c:     	ldp	x22, x21, [sp, #0x30]
10001c560:     	ldp	x24, x23, [sp, #0x20]
10001c564:     	ldp	x26, x25, [sp, #0x10]
10001c568:     	ldp	x28, x27, [sp], #0x60
10001c56c:     	ret
10001c570:     	bl	0x100004250 <_rig.runtime.oom>

000000010001c574 <_rig.runtime.outFixed__func_363>:
10001c574:     	adrp	x8, 0x100083000 <_rig.runtime.stdout_buffer+0x1450>
10001c578:     	ldrb	w8, [x8, #0xc80]
10001c57c:     	tbz	w8, #0x0, 0x10001c5d8 <_rig.runtime.outFixed__func_363+0x64>
10001c580:     	adrp	x8, 0x100083000 <_rig.runtime.stdout_buffer+0x1450>
10001c584:     	add	x8, x8, #0xc60
10001c588:     	ldp	x9, x8, [x8]
10001c58c:     	sub	x9, x9, x8
10001c590:     	cmp	x9, #0xf
10001c594:     	b.lo	0x10001c5d8 <_rig.runtime.outFixed__func_363+0x64>
10001c598:     	adrp	x9, 0x100083000 <_rig.runtime.stdout_buffer+0x1450>
10001c59c:     	add	x9, x9, #0xc58
10001c5a0:     	ldr	x10, [x9]
10001c5a4:     	add	x8, x10, x8
10001c5a8:     	ldr	x10, [x0]
10001c5ac:     	ldr	w11, [x0, #0x8]
10001c5b0:     	ldrh	w12, [x0, #0xc]
10001c5b4:     	ldrb	w13, [x0, #0xe]
10001c5b8:     	strb	w13, [x8, #0xe]
10001c5bc:     	strh	w12, [x8, #0xc]
10001c5c0:     	str	w11, [x8, #0x8]
10001c5c4:     	str	x10, [x8]
10001c5c8:     	ldr	x8, [x9, #0x10]
10001c5cc:     	add	x8, x8, #0xf
10001c5d0:     	str	x8, [x9, #0x10]
10001c5d4:     	ret
10001c5d8:     	mov	w1, #0xf                ; =15
10001c5dc:     	b	0x100002efc <_rig.runtime.outBytes>

000000010001c5e0 <_rig.runtime.outFixed__func_362>:
10001c5e0:     	adrp	x8, 0x100083000 <_rig.runtime.stdout_buffer+0x1450>
10001c5e4:     	ldrb	w8, [x8, #0xc80]
10001c5e8:     	tbz	w8, #0x0, 0x10001c630 <_rig.runtime.outFixed__func_362+0x50>
10001c5ec:     	adrp	x8, 0x100083000 <_rig.runtime.stdout_buffer+0x1450>
10001c5f0:     	add	x8, x8, #0xc60
10001c5f4:     	ldp	x9, x8, [x8]
10001c5f8:     	sub	x9, x9, x8
10001c5fc:     	cmp	x9, #0x10
10001c600:     	b.lo	0x10001c630 <_rig.runtime.outFixed__func_362+0x50>
10001c604:     	adrp	x9, 0x100083000 <_rig.runtime.stdout_buffer+0x1450>
10001c608:     	add	x9, x9, #0xc58
10001c60c:     	ldr	x10, [x9]
10001c610:     	adrp	x11, 0x100031000 <___anon_12187>
10001c614:     	add	x11, x11, #0x71c
10001c618:     	ldr	q0, [x11]
10001c61c:     	str	q0, [x10, x8]
10001c620:     	ldr	x8, [x9, #0x10]
10001c624:     	add	x8, x8, #0x10
10001c628:     	str	x8, [x9, #0x10]
10001c62c:     	ret
10001c630:     	adrp	x0, 0x100031000 <___anon_12187>
10001c634:     	add	x0, x0, #0x71c
10001c638:     	mov	w1, #0x10               ; =16
10001c63c:     	b	0x100002efc <_rig.runtime.outBytes>

000000010001c640 <___rig_main.int_ensure_pass>:
10001c640:     	sub	sp, sp, #0x70
10001c644:     	stp	x28, x27, [sp, #0x10]
10001c648:     	stp	x26, x25, [sp, #0x20]
10001c64c:     	stp	x24, x23, [sp, #0x30]
10001c650:     	stp	x22, x21, [sp, #0x40]
10001c654:     	stp	x20, x19, [sp, #0x50]
10001c658:     	stp	x29, x30, [sp, #0x60]
10001c65c:     	mov	x19, x0
10001c660:     	adrp	x6, 0x100083000 <_rig.runtime.stdout_buffer+0x1450>
10001c664:     	ldrb	w8, [x6, #0xbb1]
10001c668:     	tbz	w8, #0x0, 0x10001c674 <___rig_main.int_ensure_pass+0x34>
10001c66c:     	mov	x20, #0x0               ; =0
10001c670:     	b	0x10001c6b8 <___rig_main.int_ensure_pass+0x78>
10001c674:     	mov	x21, x6
10001c678:     	mov	x1, sp
10001c67c:     	mov	w0, #0x8                ; =8
10001c680:     	bl	0x10002f36c <dyld_stub_binder+0x10002f36c>
10001c684:     	cmn	w0, #0x1
10001c688:     	b.eq	0x10001c6a4 <___rig_main.int_ensure_pass+0x64>
10001c68c:     	ldp	x8, x9, [sp]
10001c690:     	mov	w10, #0xca00            ; =51712
10001c694:     	movk	w10, #0x3b9a, lsl #16
10001c698:     	mul	x8, x8, x10
10001c69c:     	adds	x20, x8, x9
10001c6a0:     	b	0x10001c6b4 <___rig_main.int_ensure_pass+0x74>
10001c6a4:     	bl	0x10002f438 <dyld_stub_binder+0x10002f438>
10001c6a8:     	ldr	w8, [x0]
10001c6ac:     	cbz	w8, 0x10001c68c <___rig_main.int_ensure_pass+0x4c>
10001c6b0:     	mov	x20, #0x0               ; =0
10001c6b4:     	mov	x6, x21
10001c6b8:     	mov	x22, #0x0               ; =0
10001c6bc:     	mov	x23, #0x101010101010101 ; =72340172838076673
10001c6c0:     	movk	x23, #0x1, lsl #48
10001c6c4:     	mov	x24, #0x7c15            ; =31765
10001c6c8:     	movk	x24, #0x7f4a, lsl #16
10001c6cc:     	movk	x24, #0x79b9, lsl #32
10001c6d0:     	movk	x24, #0x9e37, lsl #48
10001c6d4:     	mov	x25, #0x655f            ; =25951
10001c6d8:     	movk	x25, #0xd75d, lsl #16
10001c6dc:     	movk	x25, #0x12e3, lsl #32
10001c6e0:     	movk	x25, #0x9685, lsl #48
10001c6e4:     	adrp	x26, 0x100030000 <dyld_stub_binder+0x100030000>
10001c6e8:     	add	x26, x26, #0xd7b
10001c6ec:     	mov	w7, #0x1                ; =1
10001c6f0:     	mov	w28, #0x4240            ; =16960
10001c6f4:     	movk	w28, #0xf, lsl #16
10001c6f8:     	adrp	x27, 0x100030000 <dyld_stub_binder+0x100030000>
10001c6fc:     	add	x27, x27, #0xe7b
