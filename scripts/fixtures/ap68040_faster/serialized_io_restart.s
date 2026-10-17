; A serialized device operand must not be consumed again after a later
; destination write fault. The bench advances this register on each read.
    org 0
    dc.l $e000,start,handler
    rept 253
    dc.l fail
    endr
    org $400
start:
    move.w #$2700,sr
    move.l #$500fc040,d0
    movec d0,dtt0
    lea ($5000f380).l,a0
    ifd INJECT_FAULT
    lea ($f400).l,a1
    else
    lea ($f404).l,a1
    endif
copy_device:
    move.l (a0),(a1)+
after_copy:
    ifd INJECT_FAULT
    cmpa.l #$f404,a1
    else
    cmpa.l #$f408,a1
    endif
    bne fail
    move.l (a0),d0
    move.l d0,($3908).l
    cmp.l #2,d0
    bne fail
    move.l (a0),d0
    cmp.l #3,d0
    bne fail
    move.l (a0),d0
    cmp.l #4,d0
    bne fail
    move.l ($f324).l,d0
    move.w #$600d,($f102).l
    bra *
handler:
    addq.l #1,($3900).l
    move.l 2(sp),($3800).l
    move.l 8(sp),($3804).l
    move.l 12(sp),($3808).l
    move.l 16(sp),($380c).l
    move.l 20(sp),($3810).l
    move.l 24(sp),($3814).l
    move.l 28(sp),($3818).l
; OS-style recovery: complete an advertised ordinary longword WB3 before
; returning. The current native frame has V clear, so this path is skipped.
    movem.l d0/a2,-(sp)
    move.w 22(sp),d0
    btst #7,d0
    beq no_writeback
    and.w #$7f,d0
    cmp.w #5,d0
    bne fail
    movea.l 32(sp),a2
    move.l 36(sp),(a2)
    bclr #7,23(sp)
no_writeback:
    movem.l (sp)+,d0/a2
    rte
fail:
    move.w #$bad0,($f102).l
    bra *
