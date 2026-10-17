// Run the existing SingleStepTests/preboot/sim040 payloads through the
// production faster CPU wrapper and transaction adapter. This tests CPU
// behavior against the Mac silicon captures; it does not test SCSI or OS boot.
`timescale 1ns/1ps
module tb_ap68040_mac_corpus;
    logic clk=0, nreset=0;
    always #5 clk=~clk;
    wire req, wr, ack, halted;
    wire [1:0] size;
    wire [31:0] addr, wdata, rdata;
    wire [255:0] status;
    wire breq, bwrite;
    wire [31:2] baddr;
    wire [3:0] be;
    wire [31:0] bwdata;
    logic back=0;
    logic [31:0] brdata=0;
    logic [31:0] mem[1048576];
    logic [15:0] image[2097152];
    string prog_file, results_file;
    longint cycles=0, maxcycles;

    wombat_cpu dut (
        .clk(clk), .nreset(nreset), .ce(1'b1), .ipl(3'd7), .ipl_autovector(1'b1),
        .berr(1'b0), .stall_hold(1'b0), .dbg_stall_flt(),
        .cache_line_valid(1'b0), .cache_line_tag(28'd0), .cache_line_data(128'd0),
        .store_buffer_ok(1'b1), .bus_req(req), .bus_write(wr), .bus_instr(),
        .bus_size(size), .bus_addr(addr), .bus_wdata(wdata), .bus_fc(),
        .bus_ack(ack), .bus_rdata(rdata),
        .walker_req(), .walker_we(), .walker_addr(), .walker_wdat(),
        .walker_ack(1'b0), .walker_data(32'd0), .walker_berr(1'b0),
        .snoop_stb(1'b0), .snoop_addr(32'd0),
        .dma_req(1'b0), .dma_write(1'b0), .dma_snoop_enable(1'b0),
        .dma_addr(30'd0), .dma_be(4'd0), .dma_wdata(32'd0),
        .dma_ack(), .dma_rdata(), .dma_mem_req(), .dma_mem_write(),
        .dma_mem_addr(), .dma_mem_be(), .dma_mem_wdata(),
        .dma_mem_ack(1'b0), .dma_mem_rdata(32'd0),
        .nresetout(), .nmi_ack_toggle(), .cacr_out(), .vbr_out(),
        .debug_busy(), .debug_fault(), .debug_halted(halted),
        .debug_status(status), .debug_status2()
    );
    wombat_bus32 bus32 (
        .clk(clk), .nreset(nreset), .ce(1'b1), .t_req(req), .t_write(wr),
        .t_size(size), .t_addr(addr), .t_wdata(wdata), .t_berr(1'b0),
        .t_ack(ack), .t_rdata(rdata), .t_active(), .b_req(breq),
        .b_write(bwrite), .b_addr(baddr), .b_be(be), .b_wdata(bwdata),
        .b_ack(back), .b_rdata(brdata)
    );
    task automatic finish_run(input bit success);
        integer f;
        f=$fopen(results_file,"wb");
        if (!f) $fatal(1,"cannot open results %s",results_file);
        for(integer i=0;i<409600;i++)
            $fwrite(f,"%c",8'(mem[(32'h100000+i)>>2] >> (24-8*(i&3))));
        $fclose(f);
        if (!success) $fatal(1,"corpus timeout/halt cycles=%0d pc=%08x",cycles,status[31:0]);
        $display("CORPUS DONE in %0d cycles; results=%s",cycles,results_file);
        $finish;
    endtask
    initial begin
        if (!$value$plusargs("prog=%s",prog_file) || !$value$plusargs("results=%s",results_file))
            $fatal(1,"missing +prog/+results");
        if (!$value$plusargs("maxcycles=%d",maxcycles)) maxcycles=2500000000;
        for(integer i=0;i<2097152;i++) image[i]=0;
        $readmemh(prog_file,image);
        for(integer i=0;i<1048576;i++) mem[i]={image[2*i],image[2*i+1]};
        // Same 8K-page identity world as the existing sim040 testbench.
        mem['h3fe000>>2]=32'h003fe203;
        for(integer k=0;k<16;k++) mem[('h3fe200+4*k)>>2]=('h3fe400+128*k)|3;
        for(integer k=0;k<512;k++) mem[('h3fe400+4*k)>>2]=(k*'h2000)|1;
        repeat(8) @(negedge clk);
        nreset=1;
    end
    always @(posedge clk) if(nreset) begin
        cycles<=cycles+1;
        back<=0;
        if(breq && !back) begin
            back<=1;
            brdata<=baddr<30'h100000 ? mem[baddr[21:2]] : 32'd0;
            if(bwrite && baddr<30'h100000)
                for(integer lane=0;lane<4;lane++)
                    if(be[3-lane]) mem[baddr[21:2]][31-8*lane-:8]<=bwdata[31-8*lane-:8];
        end
        if(req && ack && wr && addr==32'h00f00000) begin
            if(wdata[15:0]!=16'h600d) $fatal(1,"bad corpus doorbell %h",wdata);
            finish_run(1);
        end
        if(halted || cycles>=maxcycles) finish_run(0);
        if(cycles!=0 && cycles%20000000==0)
            $display("HEARTBEAT %0d cycles pc=%08x",cycles,status[31:0]);
    end
endmodule
