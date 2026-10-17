; Self-checking Q800 adapter test. F3xx is the bench control window.
    org 0
    dc.l $e000,start
    dc.l berr_handler
    rept 23
    dc.l unexpected
    endr
    dc.l irq_handler
    rept 229
    dc.l unexpected
    endr
    org $400
start:
    move.w #$2700,sr
; Address-register TST flags depend on the actual low word, including
; relocated harness addresses. Check both signs with explicit values.
    movea.l #$00001800,a0
    tst.w a0
    bmi fail
    beq fail
    movea.l #$fffffffe,a0
    tst.w a0
    bpl fail
    beq fail
; RTD #4 discards a caller-supplied argument, not the caller's return PC.
    movea.l sp,a5
    clr.l -(sp)
    bsr rtd_sub
    cmpa.l sp,a5
    bne fail
    move.l #$11223344,($3000).l
    move.b #$aa,($3001).l
    move.w #$bbcc,($3002).l
    cmp.l #$11aabbcc,($3000).l
    bne fail
    move.l #$12345678,($3001).l
    cmp.l #$12345678,($3001).l
    bne fail
    fmove.l #3,fp0
    fadd.l #2,fp0
    fmove.l fp0,d0
    cmp.l #5,d0
    bne fail
; Physical I/O must not be retained in the D-cache, even with TC/TTRs off.
; The bench register advances on each physical read of its longword.
    move.l #$80000000,d0
    movec d0,cacr
    move.l ($5000f380).l,d0
    cmp.l #1,d0
    bne fail
    move.l ($5000f380).l,d0
    cmp.l #2,d0
    bne fail
; VRAM is also outside the platform's physical cacheable windows.
    move.l ($f900f380).l,d0
    cmp.l #3,d0
    bne fail
    move.l ($f900f380).l,d0
    cmp.l #4,d0
    bne fail
    moveq #0,d0
    movec d0,cacr
; A native bus error must produce a restartable format-7 frame.
    clr.l ($3900).l
    move.l ($f400).l,d0
    cmp.l #$face1234,d0
    bne fail
    cmp.l #1,($3900).l
    bne fail
; Interrupt acknowledge stays local to the adapter (autovector level 2).
    clr.l ($3904).l
    move.w #$2000,sr
    move.w #1,($f310).l
wait_irq:
    tst.l ($3904).l
    beq wait_irq
    move.w #$2700,sr
; User data: copyback; supervisor data: uncached bench, stack, memory.
    move.l #$0000a040,d0
    movec d0,dtt1
    move.l #$00008020,d0
    movec d0,dtt0
    moveq #1,d0
    movec d0,sfc
    movec d0,dfc
    move.l #$80008000,d0
    movec d0,cacr
    move.l #$aaaa5555,($8000).l
    lea ($8000).l,a0
    move.l #$11223344,d0
    moves.l d0,(a0)
; DMA reads a dirty line. Backing memory must remain the original value.
    move.w #1,($f300).l
wait_read:
    tst.w ($f304).l
    beq wait_read
    cmp.l #$11223344,($f308).l
    bne fail
; DMA writes an arbitrary byte mask into that dirty line.
    move.w #2,($f300).l
wait_write:
    tst.w ($f304).l
    beq wait_write
    moves.l (a0),d0
    cmp.l #$11bbcc44,d0
    bne fail
    cpusha dc
    cmp.l #$11bbcc44,($8000).l
    bne fail
; A clean line must be invalidated before DMA writes memory.
    move.w #3,($f300).l
wait_clean:
    tst.w ($f304).l
    beq wait_clean
    moves.l (a0),d0
    cmp.l #$55bbccaa,d0
    bne fail
; A longword SCSI-like access parks while HPS needs a DMA completion.
    move.l ($f324).l,d0
    cmp.l #$01234567,d0
    bne fail
    move.w #$600d,($f102).l
done:
    bra done
rtd_sub:
    rtd #4
berr_handler:
    addq.l #1,($3900).l
    rte
irq_handler:
    move.w #0,($f310).l
    addq.l #1,($3904).l
    rte
unexpected:
fail:
    move.w #$bad0,($f102).l
    bra fail
