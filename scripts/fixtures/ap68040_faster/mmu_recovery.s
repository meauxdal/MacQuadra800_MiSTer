; Short real-platform recovery comparison. KIND selects one fault contract.
; 8K pages; code/handler, tables, stack and result log always stay resident.
RESULT equ $3200
FRAME equ $3100
    ifge CACHE-2
PAGEATTR equ $39
    else
PAGEATTR equ $59
    endif
    org 0
    dc.l $e000,start,handler
    rept 253
    dc.l fail
    endr
    org $400
start:
    move.w #$2700,sr
    lea ($3000).l,a0
    moveq #0,d0
    move.w #255,d1
clear_log:
    move.l d0,(a0)+
    dbra d1,clear_log
    lea ($4400).l,a0
    moveq #0,d0
    moveq #31,d1
pages:
    move.l d0,d2
    add.l #$59,d2
    move.l d2,(a0)+
    add.l #$2000,d0
    dbra d1,pages
    move.l #$4203,($4000).l
    move.l #$4403,($4200).l
    move.l #$4603,($40a0).l
    move.l #$4803,($46f0).l
    move.l #$50f10059,($4820).l
    move.l #$4a03,($41fc).l
    move.l #$4c03,($4bfc).l
    ifne CACHE
    move.l #$39,($4400).l
    endif
    ifge CACHE-2
    move.l #$10039,($4420).l
    move.l #$12039,($4424).l
    move.l #$18039,($4430).l
    endif
    move.l #$11223344,($18000).l
    move.w #$3344,($191df).l
    move.l #$55667788,($10000).l
    clr.l ($12002).l
    move.l #$aabbccdd,($11ffe).l
    move.l #$10,($10010).l
; Handler replaces just the selected descriptor, then invalidates ATCs.
    move.l #$4420,($3000).l
    move.l #$10000+PAGEATTR,($3004).l
    ifeq KIND
    clr.l ($4420).l
    endif
    ifeq KIND-1
    clr.l ($4420).l
    endif
    ifeq KIND-2
    move.l #$10004+PAGEATTR,($4420).l
    endif
    ifeq KIND-3
    move.l #$4424,($3000).l
    move.l #$12000+PAGEATTR,($3004).l
    clr.l ($4424).l
    endif
    ifeq KIND-4
    move.l #$4424,($3000).l
    move.l #$12000+PAGEATTR,($3004).l
    clr.l ($4424).l
    endif
    ifeq KIND-6
    clr.l ($4420).l
    endif
    ifeq KIND-7
    move.l #$10004+PAGEATTR,($4420).l
    endif
    ifeq KIND-8
    move.l #$4e751234,($6000).l
    move.l #$440c,($3000).l
    move.l #$6059,($3004).l
    clr.l ($440c).l
    endif
    ifge KIND-9
    ifle KIND-10
    clr.l ($4420).l
    endif
    endif
    ifeq KIND-11
    move.l #$4c74,($3000).l
    move.l #$18000+PAGEATTR,($3004).l
    clr.l ($4c74).l
    endif
    move.l #$4000,d0
    movec d0,urp
    movec d0,srp
    pflusha
    move.l #$c000,d0
    movec d0,tc
    ifne CACHE
    move.l #$80008000,d0
    movec d0,cacr
    endif
    lea ($18000).l,a0
    lea ($10000).l,a1
    move.l #$12345678,d4
    move.l #$87654321,d5
    ifeq KIND-3
    lea ($11fff).l,a0
    endif
    ifeq KIND-4
    lea ($11fff).l,a1
    endif
    ifeq KIND-11
    lea ($ffffb1df).l,a0
    endif
    ifge KIND-5
    ifle KIND-6
    lea ($50f10000).l,a0
    move.b #2,$30(a0)
    move.b #1,$30(a0)
    move.b #$11,$20(a0)
    move.b #$22,$20(a0)
    move.b #$33,$20(a0)
    move.b #$44,$20(a0)
    lea $20(a0),a0
    endif
    endif
    move.w #$2704,sr
    ifeq KIND-10
    moveq #0,d4
    move.w #$2700,sr
    endif
faulting:
    ifeq KIND
    move.l (a1)+,d4
    endif
    ifeq KIND-1
    move.l (a0)+,(a1)+
    endif
    ifeq KIND-2
    move.l (a0)+,(a1)+
    endif
    ifeq KIND-3
    move.w (a0)+,d4
    endif
    ifeq KIND-4
    move.l (a0)+,(a1)+
    endif
    ifeq KIND-5
    move.b (a0),(a1)+
    endif
    ifeq KIND-6
    move.b (a0),(a1)+
    endif
    ifeq KIND-7
    add.l d4,$10(a1)
    endif
    ifeq KIND-8
    jsr ($6000).l
    endif
    ifge KIND-9
    ifle KIND-10
    move.l d4,(a1)
    endif
    endif
    ifeq KIND-11
    move.w (a0),d4
    endif
resumed:
    move.w sr,RESULT+$24
    move.l a0,RESULT+$10
    move.l a1,RESULT+$14
    move.l d4,RESULT+$18
    move.l d5,RESULT+$1c
    move.l #faulting,RESULT+$28
    move.l #resumed,RESULT+$2c
    ifge KIND-5
    ifle KIND-6
    move.b (a0),RESULT+$20
    move.b (a0),RESULT+$21
    endif
    endif
    move.l ($10000).l,RESULT+$30
    move.l ($11ffe).l,RESULT+$34
    move.l ($12002).l,RESULT+$38
    move.l ($10010).l,RESULT+$3c
    cpusha dc
    moveq #0,d0
    movec d0,cacr
    movec d0,tc
    pflusha
    move.w #$600d,($f102).l
    bra *
handler:
    cmp.w #$7008,6(sp)
    bne fail
    addq.l #1,RESULT
    cmp.l #1,RESULT
    bne fail
    move.l a1,RESULT+4
    move.l a0,RESULT+8
    move.l d4,RESULT+$c
    movem.l d0-d3/a0-a2,-(sp)
    lea 28(sp),a0
    lea (FRAME).l,a1
    moveq #29,d0
capture:
    move.w (a0)+,(a1)+
    dbra d0,capture
    movea.l ($3000).l,a0
    move.l (a0),RESULT+$40
    move.l ($3004).l,(a0)
    pflusha
; OS order: repair, then advertised ordinary writebacks 1, 2, 3.
; All CPU-generated slots are invalid in the current cores. Preserve that
; evidence in FRAME; never invent V or advance the stacked PC here.
    move.w 46(sp),d0
    lea 68(sp),a2
    bsr complete_wb
    bclr #7,47(sp)
    move.w 44(sp),d0
    lea 60(sp),a2
    bsr complete_wb
    bclr #7,45(sp)
    move.w 42(sp),d0
    lea 52(sp),a2
    bsr complete_wb
    bclr #7,43(sp)
    movem.l (sp)+,d0-d3/a0-a2
    rte
complete_wb:
    btst #7,d0
    beq no_wb
    move.w d0,d1
    and.w #$60,d1
; Only ordinary longword writebacks are within this probe's completion
; implementation. Fail explicitly if another shape becomes advertised.
    tst.w d1
    bne fail
    movea.l (a2),a0
    move.l 4(a2),d2
    move.l d2,(a0)
    addq.l #1,RESULT+$44
no_wb:
    rts
fail:
    cpusha dc
    moveq #0,d0
    movec d0,cacr
    movec d0,tc
    move.w #$bad0,($f102).l
    bra *
