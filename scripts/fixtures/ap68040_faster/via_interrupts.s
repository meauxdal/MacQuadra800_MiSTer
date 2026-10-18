; Real VIA1 one-shot timers -> IOSB IPL1 -> CPU autovector -> RTE.
; MODE 0=uncached, 1=ROM TTRs/caches, 2=8K MMU/low I/O alias/copyback.
; WAIT 0=interrupts amid odd-address RMWs, 1=STOP, 2=masked pending -> STOP.
; TIMER 0=T1, 1=T2. No synthetic IRQ or bench timer is injected.
RESULT equ $3200
    ifeq MODE-2
VIA equ $00f00000
    else
VIA equ $50f00000
    endif
    ifeq TIMER
TLO equ $800
THI equ $a00
FLAG equ $40
    else
TLO equ $1000
THI equ $1200
FLAG equ $20
    endif
    org 0
    dc.l $e000,start
    rept 23
    dc.l fail
    endr
    dc.l irq1
    rept 230
    dc.l fail
    endr
    org $400
start:
    move.w #$2700,sr
    lea ($3000).l,a0
    moveq #0,d0
    move.w #511,d1
clear:
    move.l d0,(a0)+
    dbra d1,clear
    move.l #$11223344,($10003).l
    move.l #$11223344,($3000).l
    ifeq MODE-1
    move.l #$807fc040,d0
    movec d0,dtt0
    move.l #$500fc040,d0
    movec d0,dtt1
    endif
    ifeq MODE-2
    lea ($4400).l,a0
    moveq #0,d0
    moveq #31,d1
pages:
    move.l d0,d2
    add.l #$59,d2
    move.l d2,(a0)+
    add.l #$2000,d0
    dbra d1,pages
    move.l #$39,($4400).l
    move.l #$10039,($4420).l
    move.l #$4203,($4000).l
    move.l #$4403,($4200).l
    move.l #$4603,($40a0).l
    move.l #$4803,($46f0).l
    move.l #$4803,($42f0).l
    move.l #$50f00059,($4800).l
    move.l #$4000,d0
    movec d0,urp
    movec d0,srp
    pflusha
    move.l #$c000,d0
    movec d0,tc
    endif
    ifne MODE
    move.l #$80008000,d0
    movec d0,cacr
    endif
    move.b #$7f,(VIA+$1c00).l
    move.b #0,(VIA+$1600).l       ; T1 one shot, T2 timed, SR disabled
    move.b #$7f,(VIA+$1a00).l
    lea ($10003).l,a0
    lea ($12005).l,a1
    movea.l #$23456789,a2
    movea.l #$3456789a,a3
    movea.l #$456789ab,a4
    movea.l #$56789abc,a5
    movea.l #$6789abcd,a6
    move.l #$01234567,d0
    move.l #$12345678,d1
    move.l #$23456789,d2
    move.l #$3456789a,d3
    moveq #1,d4
    move.l #$56789abc,d5
    moveq #0,d6
    moveq #31,d7
round:
    addq.l #1,d6
    move.l d6,RESULT+$20
    movem.l d0-d7/a0-a6,($3400).l
    move.b #$7f,(VIA+$1a00).l
    move.b d4,(VIA+TLO).l
    move.b #0,(VIA+THI).l
    move.b #$80+FLAG,(VIA+$1c00).l
    ifeq WAIT
    move.w #$2000,sr
    rept 16
    addq.l #1,(a0)
    endr
    endif
    ifeq WAIT-1
    stop #$2000
woke:
    endif
    ifeq WAIT-2
pending:
    ifeq TIMER
    btst #6,(VIA+$1a00).l
    else
    btst #5,(VIA+$1a00).l
    endif
    beq pending
    cmp.l RESULT,d6              ; IRQ must remain masked
    beq fail
    stop #$2000
woke:
    endif
wait_irq:
    cmp.l RESULT,d6
    bne wait_irq
    move.w #$2700,sr
    movem.l d0-d7/a0-a6,($3480).l
    lea ($3400).l,a2
    lea ($3480).l,a3
    moveq #14,d2
compare:
    move.l (a2)+,d3
    cmp.l (a3)+,d3
    bne fail
    dbra d2,compare
    movem.l ($3400).l,d0-d7/a0-a6
    ifeq WAIT
    add.l #16,($3000).l
    endif
    move.l (a0),RESULT+$18
    move.l ($3000).l,RESULT+$1c
    move.l (a0),d2
    cmp.l ($3000).l,d2
    bne fail
    move.l ($3408).l,d2
    addq.l #1,RESULT+4
    addq.b #3,d4                 ; E tick phase / timer count sweep, 1..94
    dbra d7,round
    move.b #$7f,(VIA+$1c00).l
    move.l sp,RESULT+$24
    cpusha dc
    moveq #0,d0
    movec d0,cacr
    movec d0,tc
    pflusha
    move.w #$600d,($f102).l
    bra *
irq1:
    movem.l d0-d7/a0-a6,-(sp)
    move.w 60(sp),RESULT+8
    move.l 62(sp),RESULT+$c
    move.w 66(sp),RESULT+$10
    cmp.w #$0064,66(sp)
    bne fail
    move.b (VIA+$1a00).l,RESULT+$14
    move.b (VIA+TLO).l,d0         ; clear the timer's flag at the real chip
    move.b (VIA+$1a00).l,RESULT+$15
    addq.l #1,RESULT
    move.l RESULT,d0
    cmp.l RESULT+$20,d0
    bne fail
    ifne WAIT
    cmp.l #woke,62(sp)
    bne fail
    endif
    movem.l (sp)+,d0-d7/a0-a6
    rte
fail:
    move.w #$bad0,($f102).l
    bra *
