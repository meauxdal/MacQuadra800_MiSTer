// Native 68040 bus to Q800 transactions. TBI converts cache lines into
// four ordinary longwords; the platform's retained-line paths still apply.
// SONIC is an alternate bus master. SC=01 lets a dirty cache supply reads
// and absorb writes. Partial DMA writes are snooped one byte at a time.
module wombat_ap68040_bus (
    input logic clk, nreset, ce,
    input logic [31:0] a, dout,
    input logic a_oe, ts_n, rw_n, lock_n,
    input logic [1:0] siz, tt,
    input logic [2:0] tm,
    output logic [31:0] din,
    output logic ta_n, tea_n, bg_n, bb_n, avec_n,
    input logic ipl_autovector, stall_hold,
    output logic stall_fault,
    output logic req, write, instr,
    output logic [1:0] size,
    output logic [31:0] addr, wdata,
    output logic [2:0] fc,
    input logic ack, berr,
    input logic [31:0] rdata,
    input logic dma_req, dma_write, snoop_enable,
    input logic [31:2] dma_addr,
    input logic [3:0] dma_be,
    input logic [31:0] dma_wdata,
    output logic dma_ack,
    output logic [31:0] dma_rdata,
    output logic dma_mem_req, dma_mem_write,
    output logic [31:2] dma_mem_addr,
    output logic [3:0] dma_mem_be,
    output logic [31:0] dma_mem_wdata,
    input logic dma_mem_ack,
    input logic [31:0] dma_mem_rdata,
    output logic [31:0] snoop_addr,
    output logic snoop_ts_n, snoop_rw_n,
    output logic [1:0] snoop_size,
    output logic [1:0] snoop_control,
    input logic mi_n, snoop_ta_n, snoop_ta_oe,
    input logic [31:0] snoop_data,
    output logic [6:0] debug_state
);
    typedef enum logic [2:0] {C_IDLE, C_WAIT, C_REPLY, C_RETRY,
                              C_PARK, C_RESUME} cstate_t;
    typedef enum logic [3:0] {D_IDLE, D_GRANT, D_START, D_LOOK,
                              D_MEM, D_TERM, D_NEXT, D_DONE} dstate_t;
    cstate_t cs;
    dstate_t ds;
    assign debug_state = {ds, cs};
    logic [31:0] response;
    logic response_err, saved, saved_err;
    logic [31:0] saved_data;
    logic [23:0] watchdog;
    logic [3:0] remaining;
    logic [1:0] lane;
    logic dma_wr_q, snoop_q;
    logic [31:2] dma_a_q;
    logic [31:0] dma_w_q;
    logic [31:0] dma_result;
    logic [3:0] selected;
    logic [5:0] shift;
    logic ack_cycle;
    logic line_first;
    logic [1:0] line_tail;

    function automatic logic [1:0] first_lane(input logic [3:0] be);
        if (be[3]) return 2'd0;
        if (be[2]) return 2'd1;
        if (be[1]) return 2'd2;
        return 2'd3;
    endfunction

    assign selected = 4'b1000 >> lane;
    assign shift = (size == 2'd0) ? (6'd24 - {1'b0,addr[1:0],3'b0}) :
                   (size == 2'd1) ? (6'd16 - {1'b0,addr[1:0],3'b0}) : 6'd0;
    assign bg_n = dma_req || ds != D_IDLE;
    assign bb_n = !(ds == D_START || ds == D_LOOK || ds == D_MEM || ds == D_TERM || ds == D_NEXT);
    assign snoop_addr = {dma_a_q, dma_wr_q ? lane : 2'b00};
    assign snoop_ts_n = ds != D_START;
    assign snoop_rw_n = !dma_wr_q;
    assign snoop_size = dma_wr_q ? 2'b01 : 2'b00;
    assign snoop_control = snoop_q ? 2'b01 : 2'b00;
    assign dma_mem_req = ds == D_MEM;
    assign dma_mem_write = dma_wr_q;
    assign dma_mem_addr = dma_a_q;
    assign dma_mem_be = dma_wr_q ? selected : 4'hf;
    assign dma_mem_wdata = dma_w_q;
    assign dma_ack = ds == D_DONE;
    assign dma_rdata = dma_result;
    assign ta_n = (ds == D_TERM) ? 1'b0 :
                  (ds == D_LOOK || ds == D_MEM) ? !(snoop_ta_oe && !snoop_ta_n) :
                  !(cs == C_REPLY && !response_err || cs == C_RETRY);
    assign tea_n = !(cs == C_REPLY && response_err || cs == C_RETRY);
    assign avec_n = !(cs == C_REPLY && ack_cycle && tm != 3'd0 && ipl_autovector);
    assign din = (ds == D_START || ds == D_LOOK || ds == D_MEM || ds == D_TERM || ds == D_NEXT) ?
                 (dma_wr_q ? dma_w_q : dma_result) : response;

    always_ff @(posedge clk) begin
        if (!nreset) begin
            cs <= C_IDLE; ds <= D_IDLE;
            req <= 0; write <= 0; instr <= 0; size <= 0;
            addr <= 0; wdata <= 0; fc <= 0;
            response <= 0; response_err <= 0; ack_cycle <= 0;
            line_first <= 0; line_tail <= 0;
            saved <= 0; saved_err <= 0; saved_data <= 0;
            watchdog <= 0; stall_fault <= 0;
            remaining <= 0; lane <= 0; dma_wr_q <= 0; snoop_q <= 0;
            dma_a_q <= 0; dma_w_q <= 0; dma_result <= 0;
        end else if (ce) begin
            stall_fault <= 0;
            if (req && !stall_hold && !ack && !berr) watchdog <= watchdog + 1'b1;
            else watchdog <= 0;
            // A parked pseudo-DMA access remains in the platform exactly once.
            // Its native bus cycle is retried so SONIC can unblock the HPS;
            // completion is saved and delivered when the CPU reissues TS.
            if (req && (cs == C_RETRY || cs == C_PARK || cs == C_RESUME) && (ack || berr)) begin
                req <= 0; saved <= 1; saved_err <= berr;
                saved_data <= rdata << shift;
            end
            case (cs)
                C_IDLE: if (a_oe && !ts_n) begin
                    addr <= a; fc <= tm; instr <= tm == 3'd2 || tm == 3'd6;
                    write <= !rw_n;
                    size <= siz == 2'b01 ? 2'd0 : siz == 2'b10 ? 2'd1 : 2'd2;
                    // Native data is on byte lanes; Q800 expects right alignment.
                    wdata <= siz == 2'b01 ? (dout >> (24 - 8*a[1:0])) & 32'hff :
                             siz == 2'b10 ? (dout >> (16 - 8*a[1:0])) & 32'hffff : dout;
                    ack_cycle <= tt == 2'b11;
                    line_first <= siz == 2'b11;
                    response_err <= 0;
                    if (tt == 2'b11) begin
                        response <= 0; cs <= C_REPLY;
                    end else begin req <= 1; cs <= C_WAIT; end
                end
                C_WAIT: begin
                    if (ack || berr || &watchdog) begin
                        req <= 0;
                        response <= rdata << shift;
                        response_err <= berr || &watchdog;
                        stall_fault <= &watchdog;
                        if (berr || &watchdog) line_tail <= 0;
                        else if (line_first) line_tail <= 2'd3;
                        else if (line_tail != 0) line_tail <= line_tail - 1'b1;
                        cs <= C_REPLY;
                    end else if (stall_hold && dma_req && lock_n && !line_first && line_tail == 0) begin
                        // Only ordinary operand cycles may be retried here:
                        // a later burst-inhibited line beat must never be retried.
                        cs <= C_RETRY;
                    end
                end
                C_REPLY: cs <= C_IDLE;
                C_RETRY: cs <= C_PARK;
                C_PARK: if (ds == D_IDLE && !dma_req) cs <= C_RESUME;
                C_RESUME: if (a_oe && !ts_n) begin
                    if (saved || ack || berr) begin
                        response <= saved ? saved_data : rdata << shift;
                        response_err <= saved ? saved_err : berr;
                        saved <= 0; req <= 0; cs <= C_REPLY;
                    end else cs <= C_WAIT;
                end
                default: cs <= C_IDLE;
            endcase
            case (ds)
                D_IDLE: if (dma_req) begin
                    dma_a_q <= dma_addr; dma_wr_q <= dma_write;
                    dma_w_q <= dma_wdata; snoop_q <= snoop_enable;
                    remaining <= dma_be; lane <= first_lane(dma_be);
                    ds <= D_GRANT;
                end
                D_GRANT: if (!a_oe) ds <= (dma_wr_q && remaining == 0) ? D_DONE : D_START;
                D_START: ds <= D_LOOK;
                D_LOOK: begin
                    if (snoop_ta_oe && !snoop_ta_n) begin
                        dma_result <= snoop_data; ds <= D_NEXT;
                    end else if (mi_n) ds <= D_MEM;
                end
                D_MEM: begin
                    if (snoop_ta_oe && !snoop_ta_n) begin
                        dma_result <= snoop_data; ds <= D_NEXT;
                    end else if (dma_mem_ack) begin
                        dma_result <= dma_mem_rdata; ds <= D_TERM;
                    end
                end
                D_TERM: ds <= D_NEXT;
                D_NEXT: begin
                    remaining <= remaining & ~selected;
                    lane <= first_lane(remaining & ~selected);
                    ds <= (dma_wr_q && |(remaining & ~selected)) ? D_START : D_DONE;
                end
                D_DONE: if (!dma_req) ds <= D_IDLE;
                default: ds <= D_IDLE;
            endcase
        end
    end
endmodule
