// Q800 integration of apolkosnik/AP68040 branch faster. The old sequential
// wrapper remains in wombat_cpu.sv for historical CPU-only regression tools.
module wombat_cpu (
    input clk, nreset, ce,
    input [2:0] ipl,
    input ipl_autovector, berr, stall_hold,
    output dbg_stall_flt,
    input cache_line_valid,
    input [31:4] cache_line_tag,
    input [127:0] cache_line_data,
    input store_buffer_ok,
    output bus_req, bus_write, bus_instr,
    output [1:0] bus_size,
    output [31:0] bus_addr, bus_wdata,
    output [2:0] bus_fc,
    input bus_ack,
    input [31:0] bus_rdata,
    output walker_req, walker_we,
    output [31:0] walker_addr, walker_wdat,
    input walker_ack,
    input [31:0] walker_data,
    input walker_berr,
    input snoop_stb,
    input [31:0] snoop_addr,
    input dma_req, dma_write, dma_snoop_enable,
    input [31:2] dma_addr,
    input [3:0] dma_be,
    input [31:0] dma_wdata,
    output dma_ack,
    output [31:0] dma_rdata,
    output dma_mem_req, dma_mem_write,
    output [31:2] dma_mem_addr,
    output [3:0] dma_mem_be,
    output [31:0] dma_mem_wdata,
    input dma_mem_ack,
    input [31:0] dma_mem_rdata,
    output nresetout,
    output reg nmi_ack_toggle,
    output [31:0] cacr_out, vbr_out,
    output debug_busy, debug_fault, debug_halted,
    output [255:0] debug_status,
    output [127:0] debug_status2
);
    wire [31:0] a, din, dout, sn_a, sn_data, pc;
    wire a_oe, ts_n, rw_n, lock_n, ta_n, tea_n, bg_n, bb_n, avec_n;
    wire [1:0] siz, tt, sn_size, sn_control;
    wire [2:0] tm;
    wire sn_ts_n, sn_rw_n, mi_n, sn_ta_n, sn_ta_oe;
    wire retire;
    wire [31:0] retire_pc;
    wire exception_event;
    wire [95:0] exception_info;
    wire load_event;
    wire [95:0] load_info;
    wire [6:0] bridge_state;
    wire [3:0] pst;
    // Match Q800's physical cacheability, independently of TC/TTR/page CM:
    // only djMEMC RAM and ROM may be retained by the CPU. Device/VRAM reads
    // must sample the platform again, even when software permits caching.
    // The native BIU samples TCI with the first TA of a line transfer.
    wire tci_n = (a[31:30] == 2'b00) || (a[31:28] == 4'h4);
    // The integrated MMU walks through the same native bus as all other
    // physical transactions. Q800's old separate walker port is idle.
    assign walker_req = 0;
    assign walker_we = 0;
    assign walker_addr = 0;
    assign walker_wdat = 0;
    assign debug_busy = !ts_n || bus_req;
    assign debug_fault = !tea_n;
    // Retain the PC field used by the machine and its debug consumers.
    // Legacy sequencer state and opcode fields no longer describe this CPU.
    // Diagnostic packet, kept off the CPU's control paths. The low PC field
    // and A040 marker retain their existing meanings.
    assign debug_status = {16'hA040, exception_event, retire, 10'd0, pst,
                           exception_info, bus_addr, retire_pc,
                           {4'd0, pst, !ta_n, !tea_n, !lock_n, !ts_n, a_oe,
                            ipl, tci_n, bridge_state, retire,
                            debug_halted, stall_hold, berr, bus_ack,
                            bus_instr, bus_write, bus_req}, pc};
    assign debug_status2 = {31'd0, load_event, load_info};
    assign cacr_out = 0;
    assign vbr_out = 0;
    always @(posedge clk) begin
        if (!nreset) nmi_ack_toggle <= 0;
        else if (ce && !avec_n && ipl == 3'b000) nmi_ack_toggle <= ~nmi_ack_toggle;
    end

    ap68040 core (
        .clk(clk), .bclk_en(ce), .rsti_n(nreset),
        .a_o(a), .a_oe(a_oe), .a_i(sn_a),
        .ts_n_i(sn_ts_n), .rw_n_i(sn_rw_n), .siz_i(sn_size), .tt_i(2'b00), .sc(sn_control),
        .mi_n(mi_n), .ta_n_o(sn_ta_n), .ta_oe(sn_ta_oe),
        .d_i(din), .d_o(dout), .d_oe(),
        .rw_n(rw_n), .siz(siz), .tt(tt), .tm(tm), .tln(), .upa(),
        .ciout_n(), .lock_n(lock_n), .locke_n(), .ts_n(ts_n), .tip_n(),
        .ta_n(ta_n), .tea_n(tea_n), .tci_n(tci_n), .tbi_n(1'b0),
        .ipl_n(ipl), .avec_n(avec_n), .br_n(), .bg_n(bg_n),
        .bb_n_i(bb_n), .bb_n_o(), .bb_oe(), .rsto_n(nresetout),
        .cdis_n(1'b1), .mdis_n(1'b1), .ipend_n(), .pst(pst),
        .dbg_pc(pc), .dbg_retire(retire), .dbg_halted(debug_halted),
        .dbg_retire_pc(retire_pc),
        .dbg_exception(exception_event), .dbg_exception_info(exception_info),
        .dbg_load(load_event), .dbg_load_info(load_info)
    );
    wombat_ap68040_bus bridge (
        .clk(clk), .nreset(nreset), .ce(ce),
        .a(a), .dout(dout), .a_oe(a_oe), .ts_n(ts_n), .rw_n(rw_n), .lock_n(lock_n),
        .siz(siz), .tt(tt), .tm(tm), .din(din),
        .ta_n(ta_n), .tea_n(tea_n), .bg_n(bg_n), .bb_n(bb_n), .avec_n(avec_n),
        .ipl_autovector(ipl_autovector), .stall_hold(stall_hold), .stall_fault(dbg_stall_flt),
        .req(bus_req), .write(bus_write), .instr(bus_instr), .size(bus_size),
        .addr(bus_addr), .wdata(bus_wdata), .fc(bus_fc),
        .ack(bus_ack), .berr(berr), .rdata(bus_rdata),
        .dma_req(dma_req), .dma_write(dma_write), .snoop_enable(dma_snoop_enable),
        .dma_addr(dma_addr), .dma_be(dma_be), .dma_wdata(dma_wdata),
        .dma_ack(dma_ack), .dma_rdata(dma_rdata),
        .dma_mem_req(dma_mem_req), .dma_mem_write(dma_mem_write),
        .dma_mem_addr(dma_mem_addr), .dma_mem_be(dma_mem_be), .dma_mem_wdata(dma_mem_wdata),
        .dma_mem_ack(dma_mem_ack), .dma_mem_rdata(dma_mem_rdata),
        .snoop_addr(sn_a), .snoop_ts_n(sn_ts_n), .snoop_rw_n(sn_rw_n),
        .snoop_size(sn_size), .snoop_control(sn_control),
        .mi_n(mi_n), .snoop_ta_n(sn_ta_n), .snoop_ta_oe(sn_ta_oe), .snoop_data(dout),
        .debug_state(bridge_state)
    );
endmodule
