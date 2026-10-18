; Run the ROM's original SCSI Manager through its real A815 dispatcher.
; Low-memory globals and initialized SCSI manager tables come from the saved
; pre-boot snapshot, injected only as program input by the runner.
RESULT equ $3200
    ifnd DEST
DEST equ $10000
    endif
    ifnd BLOCKS
BLOCKS equ 1
    endif
    ifnd READSEL
READSEL equ 5
    endif
    org 0
    dc.l $e000,start
    rept 254
    dc.l fail
    endr
    org $2000
start:
    move.w #$2700,sr
    move.l #$408099b0,($28).l
    move.l #$40807460,($e54).l
    moveq #0,d6
    ifne MODE
    move.l #$807fc040,d0
    movec d0,dtt0
    move.l #$500fc040,d0
    movec d0,dtt1
    move.l #$80008000,d0
    movec d0,cacr
    endif
    move.w #16383,d0
host_ready:
    dbra d0,host_ready
    move.b #2,($50f10030).l
    clr.l RESULT
    clr.w status
    clr.w message
    move.l #$d15ea5ed,(DEST-4).l
    move.l #$d15ea5ed,(DEST+BYTES).l
; Pascal caller allocates result, pushes parameters, then selector.
    clr.w -(sp)
    move.w #1,-(sp)              ; SCSIGet
    dc.w $a815
    move.w (sp)+,RESULT+4
    bne fail
    addq.l #1,RESULT
    clr.w -(sp)
    move.w #TARGET,-(sp)
    move.w #2,-(sp)              ; SCSISelect
    dc.w $a815
    move.w (sp)+,RESULT+6
    bne fail
    addq.l #1,RESULT
    clr.w -(sp)
    pea cdb(pc)
    move.w #10,-(sp)
    move.w #3,-(sp)              ; SCSICmd
    dc.w $a815
    move.w (sp)+,RESULT+8
    bne fail
    addq.l #1,RESULT
    clr.w -(sp)
    pea tib(pc)
    move.w #READSEL,-(sp)        ; SCSIRead=5 or SCSIRBlind=8
    dc.w $a815
    move.w (sp)+,RESULT+$a
    bne fail
    addq.l #1,RESULT
    clr.w -(sp)
    pea status(pc)
    pea message(pc)
    move.l #180,-(sp)
    move.w #4,-(sp)              ; SCSIComplete
    dc.w $a815
    move.w (sp)+,RESULT+$c
    bne fail
    addq.l #1,RESULT
    move.w status(pc),RESULT+$e
    bne fail
    move.w message(pc),RESULT+$10
    bne fail
    move.l sp,RESULT+$14
    cmpa.l #$e000,sp
    bne fail
    cpusha dc
    moveq #0,d0
    movec d0,cacr
    lea (DEST).l,a0
    lea ($8000).l,a1
    move.w #BYTES-1,d7
check:
    move.b (a0)+,d0
    cmp.b (a1)+,d0
    bne fail
    dbra d7,check
    cmp.l #$d15ea5ed,(DEST-4).l
    bne fail
    cmp.l #$d15ea5ed,(DEST+BYTES).l
    bne fail
    move.w #$600d,($f102).l
    bra *
cdb:
    dc.b $28,0,0,0,0,LBA,0,0,BLOCKS,0
tib:
    dc.w 1
    dc.l DEST,BYTES
    dc.w 7
    dc.l 0,0
status: dc.w 0
message: dc.w 0
fail:
    move.w sr,RESULT+$18
    move.l d0,RESULT+$1c
    move.l a0,RESULT+$20
    move.l a1,RESULT+$24
    move.l d7,RESULT+$28
    cpusha dc
    moveq #0,d0
    movec d0,cacr
    move.w #$bad0,($f102).l
    bra *
