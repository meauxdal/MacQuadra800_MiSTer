; ROM dialect from verilator/tb_ncr53c96.sv:rom_command/read_regs.
; IOSB byte/word base port and ROM mirrored longword port ($50F50100).
; All paths execute from RAM so MMU/cache cases use identical instruction data.
    org 0
    dc.l $e000,start
    rept 254
    dc.l fail
    endr
    org $400
start:
    move.w #$2700,sr
; The normal CD capability probe uses the command/response HPS windows.
; Allow its two bounded host round trips before the first selection.
    move.w #16383,d0
host_ready:
    dbra d0,host_ready
    ifne MODE
    move.l #$807fc040,d0
    movec d0,dtt0
    move.l #$500fc040,d0
    movec d0,dtt1
    endif
    ifge MODE-2
; 8K tables with the saved page's CM=2/DT=1/U/M attributes ($59).
; Map RAM through 256K, both physical SCSI port images and the low alias.
    lea ($4400).l,a0
    moveq #$19,d0
    moveq #31,d1
ram_pages:
    move.l d0,(a0)+
    add.l #$2000,d0
    dbra d1,ram_pages
    lea ($4800).l,a0
    move.l #$50f00059,d0
    moveq #31,d1
io_pages:
    move.l d0,(a0)+
    add.l #$2000,d0
    dbra d1,io_pages
    move.l #$50f40079,d0
    moveq #31,d1
bulk_pages:
    move.l d0,(a0)+
    add.l #$2000,d0
    dbra d1,bulk_pages
    move.l #$4203,($4000).l
    move.l #$4603,($40a0).l
    move.l #$4403,($4200).l
    move.l #$4803,($46f0).l
    move.l #$4883,($46f4).l
    move.l #$4803,($42f0).l
    move.l #$4883,($42f4).l
    move.l #$4000,d0
    movec d0,urp
    movec d0,srp
    moveq #0,d0
    movec d0,dtt0
    movec d0,dtt1
    pflusha
    move.l #$c000,d0
    movec d0,tc
    endif
    ifne MODE
    move.l #$80008000,d0
    movec d0,cacr
    endif
    lea (IOBASE).l,a0
    lea $100(a0),a2
    lea ($40000+$100)(a0),a3
    lea (DEST).l,a1
    move.b #2,$30(a0)
    move.b #TARGET,$40(a0)
    move.b #1,$30(a0)
    move.b #1,(a0)
    clr.b $10(a0)
    move.b #$c1,$30(a0)
    move.b #1,$30(a0)
    move.b #1,(a0)
    clr.b $10(a0)
    move.b #$90,$30(a0)
    move.b #$28,$20(a0)
    clr.b $20(a0)
    clr.b $20(a0)
    clr.b $20(a0)
    clr.b $20(a0)
    move.b #LBA,$20(a0)
    clr.b $20(a0)
    clr.b $20(a0)
    move.b #BLOCKS,$20(a0)
    clr.b (a2)
    bsr irq_regs
    and.b #7,d0
    cmp.b #1,d0
    bne fail
    move.l #BYTES/16-1,d7
burst:
    move.b #16,(a0)
    clr.b $10(a0)
    move.b #$90,$30(a0)
gate:
    btst #4,$40(a0)
    beq gate
    btst #4,$70(a0)
    beq gate
    ifd MIXED
    move.b (a2),(a1)+
    move.w (a2),(a1)+
    move.l (a3),(a1)+
    move.l (a3),(a1)+
    move.l (a3),(a1)+
    move.b (a2),(a1)+
    else
    move.l (a3),(a1)+
    move.l (a3),(a1)+
    move.l (a3),(a1)+
    move.l (a3),(a1)+
    endif
    bsr irq_regs
    dbra d7,burst
    and.b #7,d0
    cmp.b #3,d0
    bne fail
    move.b #$11,$30(a0)
    bsr irq_regs
    btst #3,d2
    beq fail
    tst.b $20(a0)
    bne fail
    tst.b $20(a0)
    bne fail
    move.b #$12,$30(a0)
    bsr irq_regs
    btst #5,d2
    beq fail
    cpusha dc
    move.w #$600d,($f102).l
    bra *
irq_regs:
    move.b $40(a0),d0
    btst #7,d0
    beq irq_regs
    move.b $60(a0),d1
    move.b $50(a0),d2
    rts
fail:
    move.w #$bad0,($f102).l
    bra *
