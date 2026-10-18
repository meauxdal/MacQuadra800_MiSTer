    org 0
    dc.l $e000,start+$40800000
    rept 254
    dc.l fail
    endr
    org $400
start:
    move.w #$2700,sr

; Hardware 19:51:31: ROM 408253CC faults dereferencing B6DB6DB6.
; Reproduce the exact pointer chase after overwriting that RAM-test pattern.
; Sweep all byte offsets in two lines, including split longword operands.
; Modes: D-cache disabled; enabled + write-through/copyback/serialized CI.
    moveq #0,d7
pointer_mode:
    cpusha dc
    moveq #0,d0
    movec d0,cacr
    movec d0,dtt1
    move.l #$0000c000,d0
    cmp.w #2,d7
    bne pointer_not_cb
    move.l #$0000c020,d0
pointer_not_cb:
    cmp.w #3,d7
    bne pointer_not_ci
    move.l #$0000c040,d0
pointer_not_ci:
    movec d0,dtt0
    moveq #0,d0
    tst.w d7
    beq pointer_cacr
    move.l #$80000000,d0
pointer_cacr:
    movec d0,cacr
    moveq #0,d6
pointer_offset:
    lea ($9000).l,a3
    adda.l d6,a3
    lea ($9200).l,a1
    adda.l d6,a1
    lea ($9400).l,a2
    adda.l d6,a2
    lea ($9600).l,a4
    adda.l d6,a4
; Fill/cache the exact source cells with the observed RAM-test value.
    move.l #$b6db6db6,$4a(a3)
    move.l #$b6db6db6,(a1)
    move.l #$b6db6db6,4(a2)
    move.l #$b6db6db6,(a4)
    move.l $4a(a3),d0
    move.l (a1),d0
    move.l 4(a2),d0
    move.l (a4),d0
; Install the intended chain without flushing between stores and loads.
    move.l a1,$4a(a3)
    move.l a2,(a1)
    move.l a4,4(a2)
    move.l #$9800,(a4)
    moveq #3,d0
    bsr pointer_rom_sequence
    cmpa.l #$9836,a0
    bne fail
    addq.l #1,d6
    cmp.w #32,d6
    bne pointer_offset
    addq.l #1,d7
    cmp.w #4,d7
    bne pointer_mode
    cpusha dc
    moveq #0,d0
    movec d0,cacr
    movec d0,dtt0
    bra pointer_finished
pointer_rom_sequence:
; Original bytes at 408253BE..408253D0, including immediate dependencies.
    mulu.w #18,d0
    movea.l $4a(a3),a0
    movea.l (a0),a0
    movea.l 4(a0),a0
    movea.l (a0),a0
    adda.l d0,a0
    rts
pointer_finished:
    move.w #$600d,($f102).l
done:
    bra done
fail:
    move.w #$bad0,($f102).l
    bra fail
