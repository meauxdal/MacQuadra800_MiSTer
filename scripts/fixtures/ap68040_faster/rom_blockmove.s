; Calls actual Quadra ROM BlockMove / accelerated MOVE16 implementation.
; ENTRY is the ROM address. STATE 0=off, 1=write-through, 2=copyback.
; SRC/DST/LENGTH selected by runner; independent expected bytes appended
; at guest $8000, initial arena bytes at $C000 (used before stack writes).
; Arena $10000..$13fff, identity mapped.
RESULT equ $3200
    org 0
    dc.l $e000,start
    rept 254
    dc.l fail
    endr
    ifd TRAPCALL
    org $2000
    else
    org $400
    endif
start:
    move.w #$2700,sr
    move.l #$00ffffff,($31a).l    ; recorded address mask
    move.b #4,($12f).l           ; recorded CPUFlag: MC68040
    move.l #$40885030,($6f4).l   ; recorded cache-flush callback (CPUSHA BC)
    ifd TRAPCALL
    move.l #$408099b0,($28).l   ; recorded line-A vector
    move.l #ENTRY,($4b8).l      ; OS trap $2E, using the real dispatcher
    endif
    lea ($10000).l,a0
    lea ($c000).l,a1
    move.w #$fff,d7
fill:
    move.l (a1)+,(a0)+
    dbra d7,fill
    ifne STATE
    move.l #$0000c000,d0
    ifeq STATE-2
    or.l #$20,d0
    endif
    movec d0,dtt0
    move.l #$500fc040,d0
    movec d0,dtt1
    move.l #$80008000,d0
    movec d0,cacr
    endif
; Make the destination and source dirty before the ROM's own copy/flush.
; Rewriting their actual values avoids changing the independent byte oracle.
    lea (SRC).l,a0
    lea (DST).l,a1
    move.b (a0),d0
    move.b d0,(a0)
    move.b (a1),d0
    move.b d0,(a1)
    move.l #LENGTH,d0
    move.l #$456789ab,d3
    move.l #$56789abc,d4
    move.l #$6789abcd,d5
    move.l #$789abcde,d6
    move.l #$89abcdef,d7
    ifd TRAPCALL
    dc.w $a02e
    else
    jsr (ENTRY).l
    endif
    move.l d0,RESULT
    move.l sp,RESULT+4
    movem.l d3-d7,RESULT+8
    move.l a0,RESULT+$1c
    move.l a1,RESULT+$20
    cpusha dc
    moveq #0,d0
    movec d0,cacr
    movec d0,dtt0
; Compare full arena, including unchanged overlap/source bytes and guards.
    lea ($10000).l,a0
    lea ($8000).l,a1
    move.w #$fff,d7
check:
    move.l (a0)+,d0
    cmp.l (a1)+,d0
    bne locate_mismatch
    dbra d7,check
    move.l #$4000,RESULT+$24
    move.w #$600d,($f102).l
    bra *
locate_mismatch:
    subq.l #4,a0
    subq.l #4,a1
find_byte:
    move.b (a0)+,d0
    cmp.b (a1)+,d0
    beq find_byte
mismatch:
    subq.l #1,a0
    move.l a0,RESULT+$28
    move.b d0,RESULT+$2c
    move.b -1(a1),RESULT+$2d
fail:
    move.w #$bad0,($f102).l
    bra *
