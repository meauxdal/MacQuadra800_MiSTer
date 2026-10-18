; Distinct-root recovery through the real Q800 platform. KIND=0..6.
; SRP VA $10000 -> PA $10000; URP VA $10000 -> PA $18000.
; User A7=$D000 -> PA $1D000, ISP=$E000 stays supervisor resident.
; Uses ordinary user FC1/2 and MOVES FC1 only; no disputed FC0/4 rule.
; Entry/return shape follows t_mmu.s user_code/u7done/h_utrap. Unlike its
; flat-memory runner, this test records full frames and physical outcomes.
RESULT equ $3200
    ifge CACHE-2
ATTR equ $39
    else
ATTR equ $59
    endif
    org 0
    dc.l $e000,start,handler
    rept 30
    dc.l fail
    endr
    dc.l user_trap                 ; vector 33, TRAP #1
    rept 222
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
    lea ($5400).l,a1
    moveq #31,d1
pages:
    move.l d0,d2
    add.l #$59,d2
    move.l d2,(a0)+
    move.l d2,(a1)+
    add.l #$2000,d0
    dbra d1,pages
    move.l #$4203,($4000).l
    move.l #$4403,($4200).l
    move.l #$5203,($5000).l
    move.l #$5403,($5200).l
    move.l #$10000+ATTR,($4420).l
    move.l #$18000+ATTR,($4430).l
    move.l #$1c000+ATTR,($4438).l
    move.l #$18000+ATTR,($5420).l
    move.l #$1c000+ATTR,($5418).l
    move.l #$1e059,($540c).l
    ifne CACHE
    move.l #$39,($4400).l
    move.l #$39,($5400).l
    endif
    move.l #$55667788,($10000).l   ; supervisor decoy
    move.l #$11223344,($18000).l   ; user data
    move.l #$40de1234,($1d000).l   ; positive source keeps incoming/result CCR equal
    move.w #$283c,($1e000).l      ; MOVE.L #$2468ACE0,D4; RTS
    move.l #$2468ace0,($1e002).l
    move.w #$4e75,($1e006).l
    ifeq KIND-5
    clr.l ($540c).l
    else
    ifeq KIND-4
    move.l #$18004+ATTR,($5420).l
    else
    clr.l ($5420).l
    endif
    endif
    ifeq KIND-6
    clr.l ($4420).l              ; handler faults at same VA via SRP
    move.l #nested_faulting,RESULT+$c
    endif
    move.l ($5420).l,RESULT+$40
    move.l ($4420).l,RESULT+$44
    move.l #$4000,d0
    movec d0,srp
    move.l #$5000,d0
    movec d0,urp
    pflusha
    move.l #$c000,d0
    movec d0,tc
    ifne CACHE
    move.l #$80008000,d0
    movec d0,cacr
    endif
    ifne KIND-6
    move.l ($10000).l,d2         ; seed supervisor ATC with decoy mapping
    endif
    move.l #$d000,d0
    movec d0,usp
    moveq #1,d0
    movec d0,sfc
    movec d0,dfc
    lea ($d000).l,a0
    lea ($10000).l,a1
    move.l #$12345678,d4
    move.l #$87654321,d5
    ifge KIND-3
    ifle KIND-4
    move.w #$2704,sr             ; MOVES preserves flags
    bra faulting
    endif
    endif
    move.w #0,-(sp)             ; normal format-0 transition to user mode
    pea faulting(pc)
    move.w #$0700,-(sp)
    rte
faulting:
    ifeq KIND
    move.l (a1)+,d4
    endif
    ifeq KIND-1
    move.l d4,(a1)+
    endif
    ifeq KIND-2
    move.l (a7)+,(a1)+
    endif
    ifeq KIND-3
    moves.l (a1)+,d4
    endif
    ifeq KIND-4
    moves.l d4,(a1)+
    endif
    ifeq KIND-5
    jsr ($6000).l
    endif
    ifeq KIND-6
    move.l (a1)+,d4
    endif
resumed:
    ifge KIND-3
    ifle KIND-4
    move.w sr,RESULT+$24
    bra supervisor_done
    endif
    endif
    trap #1
    bra fail
user_trap:
    move.w (sp),RESULT+$24       ; SR before TRAP changed privilege
    addq.l #1,RESULT+$50
    ori.w #$2000,(sp)
    move.l #supervisor_done,2(sp)
    rte
supervisor_done:
    move.l a0,RESULT+$10
    move.l a1,RESULT+$14
    move.l d4,RESULT+$18
    move.l d5,RESULT+$1c
    movec usp,d0
    move.l d0,RESULT+$20
    move.l #faulting,RESULT+$28
    move.l #resumed,RESULT+$2c
    cpusha dc
    move.l ($18000).l,RESULT+$30
    move.l ($10000).l,RESULT+$34
    move.l ($1d000).l,RESULT+$38
    move.l sp,RESULT+$3c
    move.l ($5420).l,RESULT+$48
    move.l ($4420).l,RESULT+$4c
    movec sfc,d0
    move.l d0,RESULT+$58
    movec dfc,d0
    move.l d0,RESULT+$5c
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
    movem.l d0-d3/a0-a2,-(sp)
    addq.l #1,RESULT
    lea 28(sp),a0
    lea ($3100).l,a1
    cmp.l #1,RESULT
    beq outer_capture
    cmp.l #2,RESULT
    bne fail
    ifne KIND-6
    bra fail
    endif
    move.l a0,RESULT+8
    lea ($3140).l,a1
    bra capture
outer_capture:
    move.l a0,RESULT+4
capture:
    moveq #29,d0
copy_frame:
    move.w (a0)+,(a1)+
    dbra d0,copy_frame
; Preserve frames verbatim. This focused root test supports the current
; V-clear restart path only; reject valid writebacks rather than ignore them.
    move.w 42(sp),d0
    or.w 44(sp),d0
    or.w 46(sp),d0
    btst #7,d0
    bne fail
    ifeq KIND-6
    cmp.l #2,RESULT
    beq inner_repair
nested_faulting:
    move.l ($10000).l,d0
    move.l d0,RESULT+$54
    bra repair_user
inner_repair:
    move.l #$10000+ATTR,($4420).l
    bra repaired
    endif
repair_user:
    ifeq KIND-5
    move.l #$1e059,($540c).l
    else
    move.l #$18000+ATTR,($5420).l
    endif
repaired:
    pflusha
    movem.l (sp)+,d0-d3/a0-a2
    rte
fail:
    moveq #0,d0
    movec d0,cacr
    movec d0,tc
    move.w #$bad0,($f102).l
    bra *
