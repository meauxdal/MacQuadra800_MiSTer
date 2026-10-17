`timescale 1ns/1ps
module tb_ap68040_faster;
    logic clk=0, nreset=0;
    always #5 clk=~clk;
    logic req, wr, instr, ack=0, berr=0, stall=0, halted;
    logic [1:0] size;
    logic [31:0] addr, wdata, rdata=0;
    logic [2:0] fc, ipl=7;
    logic dma_req=0, dma_wr=0, dma_ack;
    logic [31:0] dma_data=0, dma_result, dma_mem_data, dma_mem_rdata=0;
    logic [31:2] dma_addr=30'h2000, dma_mem_addr;
    logic [3:0] dma_be=15, dma_mem_be;
    logic dma_mem_req, dma_mem_write, dma_mem_ack=0;
    logic [255:0] debug_status;
    logic [7:0] mem[65536];
    logic [15:0] image[32768];
    string program_file;
    integer cycles=0, transfers=0, dma_transfers=0, dma_op=0;
    integer delay_count=0, dma_delay=0;
    logic busy=0, fault_armed=1, dma_done=0, overlap_done=0;
    logic [31:0] saved_addr, saved_wdata;
    logic saved_write;
    logic [1:0] saved_size;
    logic waits;
    integer overlap_count=0;
    integer io_reads=0;
    integer diagnostic_faults=0;
    logic expected_retire=0;
    logic [31:0] expected_retire_pc=0;
    always @(posedge clk) begin
        expected_retire<=dut.core.be.wb_commit && dut.core.be.wb_u.last;
        expected_retire_pc<=dut.core.be.wb_u.pc;
    end
    always @(negedge clk)
        if(nreset && $test$plusargs("check_diag") && expected_retire &&
           (!debug_status[238] || debug_status[95:64]!=expected_retire_pc))
            $fatal(1,"retirement pulse/PC pair does not identify the committed instruction");

    wombat_cpu dut (
        .clk(clk), .nreset(nreset), .ce(1'b1), .ipl(ipl), .ipl_autovector(1'b1),
        .berr(berr), .stall_hold(stall), .dbg_stall_flt(),
        .cache_line_valid(1'b0), .cache_line_tag(28'd0), .cache_line_data(128'd0),
        .store_buffer_ok(1'b1), .bus_req(req), .bus_write(wr), .bus_instr(instr),
        .bus_size(size), .bus_addr(addr), .bus_wdata(wdata), .bus_fc(fc),
        .bus_ack(ack), .bus_rdata(rdata),
        .walker_req(), .walker_we(), .walker_addr(), .walker_wdat(),
        .walker_ack(1'b0), .walker_data(32'd0), .walker_berr(1'b0),
        .snoop_stb(1'b0), .snoop_addr(32'd0),
        .dma_req(dma_req), .dma_write(dma_wr), .dma_snoop_enable(1'b1),
        .dma_addr(dma_addr), .dma_be(dma_be), .dma_wdata(dma_data),
        .dma_ack(dma_ack), .dma_rdata(dma_result),
        .dma_mem_req(dma_mem_req), .dma_mem_write(dma_mem_write),
        .dma_mem_addr(dma_mem_addr), .dma_mem_be(dma_mem_be), .dma_mem_wdata(dma_mem_data),
        .dma_mem_ack(dma_mem_ack), .dma_mem_rdata(dma_mem_rdata),
        .nresetout(), .nmi_ack_toggle(), .cacr_out(), .vbr_out(),
        .debug_busy(), .debug_fault(), .debug_halted(halted),
        .debug_status(debug_status), .debug_status2()
    );
    function automatic logic [31:0] read_mem(input logic [31:0] a, input integer count);
        logic [31:0] value;
        value=0;
        for(integer i=0;i<count;i++) value=(value<<8)|{24'd0,mem[(a+i)&65535]};
        return value;
    endfunction
    initial begin
        waits=$test$plusargs("waits");
        if (!$value$plusargs("prog=%s",program_file)) $fatal(1,"missing +prog");
        for(integer i=0;i<65536;i++) mem[i]=0;
        for(integer i=0;i<32768;i++) image[i]=0;
        $readmemh(program_file,image);
        for(integer i=0;i<32768;i++) begin mem[2*i]=image[i][15:8]; mem[2*i+1]=image[i][7:0]; end
        repeat(8) @(negedge clk);
        nreset=1;
    end
    always @(posedge clk) if(nreset) begin
        if ($test$plusargs("trace") && dut.retire) $display("RETIRE pc=%h sr=%h",debug_status[31:0],dut.core.sr);
        cycles<=cycles+1;
        if ($test$plusargs("check_diag") && debug_status[239] && debug_status[223:216]==8'd2) begin
            diagnostic_faults<=diagnostic_faults+1;
            if(debug_status[215:212]!=4'd7 || debug_status[175:144]!=32'hf400 ||
               debug_status[143:128]!=16'h0105 ||
               read_mem(debug_status[207:176],2)!=32'h2039)
                $fatal(1,"wrong native access-fault diagnostic %h",debug_status[223:128]);
        end
        if(cycles>200000 || halted) $fatal(1,"CPU timeout/halt pc=%h cs=%d ds=%d",debug_status[31:0],dut.bridge.cs,dut.bridge.ds);
        ack<=0; berr<=0; dma_mem_ack<=0;
        if(dma_req && dma_ack) begin
            dma_req<=0; dma_done<=1;
            if(dma_op==1 && dma_result!=32'h11223344) $fatal(1,"dirty DMA read %h",dma_result);
            if(dma_op==1 && read_mem(32'h8000,4)!=32'haaaa5555) $fatal(1,"dirty DMA read unexpectedly changed memory");
            if(dma_op==4) begin overlap_done<=1; stall<=0; end
        end
        // DMA memory is independently available while a CPU I/O access waits.
        if(dma_mem_req && !dma_mem_ack) begin
            if(dma_delay!=0) dma_delay<=dma_delay-1;
            else begin
                dma_mem_ack<=1;
                dma_mem_rdata<=read_mem({dma_mem_addr,2'b00},4);
                dma_transfers<=dma_transfers+1;
                if(dma_mem_write) for(integer i=0;i<4;i++)
                    if(dma_mem_be[3-i]) mem[{dma_mem_addr[15:2],2'b00}+i]<=dma_mem_data[31-8*i-:8];
            end
        end
        if(!busy && req && !ack && !berr) begin
            busy<=1; saved_addr<=addr; saved_write<=wr; saved_size<=size; saved_wdata<=wdata;
            delay_count<=waits ? integer'($urandom_range(0,7)) : 0;
            transfers<=transfers+1;
            if(addr==32'hf324) begin
                overlap_count<=overlap_count+1; stall<=1;
                dma_req<=1; dma_wr<=0; dma_op<=4; dma_done<=0; dma_delay<=5;
            end
        end else if(busy) begin
            if(delay_count!=0) delay_count<=delay_count-1;
            else if(saved_addr!=32'hf324 || overlap_done) begin
                busy<=0;
                if(saved_addr==32'hf400 && fault_armed) begin berr<=1; fault_armed<=0; end
                else begin
                    if ($test$plusargs("trace")) $display("BUS %s a=%h sz=%d wd=%h rd=%h",saved_write?"W":"R",saved_addr,saved_size,saved_wdata,read_mem(saved_addr,1<<saved_size));
                    ack<=1;
                    rdata<=read_mem(saved_addr,1<<saved_size);
                    if(saved_addr==32'hf400) rdata<=32'hface1234;
                    if(saved_addr==32'h5000f380 || saved_addr==32'hf900f380) begin
                        io_reads<=io_reads+1;
                        rdata<=32'(io_reads+1);
                        if ($test$plusargs("trace")) $display("DEVICE R a=%h value=%h",saved_addr,32'(io_reads+1));
                    end
                    if(saved_addr==32'hf324) rdata<=32'h01234567;
                    if(saved_addr==32'hf304) rdata<={31'd0,dma_done};
                    if(saved_addr==32'hf308) rdata<=dma_result;
                    if(saved_write) begin
                        for(integer i=0;i<(1<<saved_size);i++) mem[(saved_addr+i)&65535]<=8'(saved_wdata >> (8*((1<<saved_size)-i-1)));
                        if(saved_addr==32'hf310) ipl<=saved_wdata[0] ? 3'd5 : 3'd7;
                        if(saved_addr==32'hf300) begin
                            dma_req<=1; dma_done<=0; dma_op<=integer'(saved_wdata);
                            dma_wr<=saved_wdata!=1;
                            dma_be<=saved_wdata==2 ? 4'b0110 : 4'b1001;
                            dma_data<=saved_wdata==2 ? 32'haabbccdd : 32'h556677aa;
                            dma_delay<=waits ? 5 : 0;
                        end
                        if(saved_addr==32'hf102) begin
                            if(saved_wdata!=32'h600d) $fatal(1,"program failed pc=%h device reads=%0d",debug_status[31:0],io_reads);
                            if(overlap_count!=1) $fatal(1,"parked I/O executed %d times",overlap_count);
                            if(io_reads!=4) $fatal(1,"physical device registers read %d times",io_reads);
                            if($test$plusargs("check_diag") && diagnostic_faults!=1)
                                $fatal(1,"expected one diagnostic access fault, got %d",diagnostic_faults);
                            $display("PASS AP68040 Q800 integration cycles=%0d CPU transfers=%0d DMA memory transfers=%0d",cycles,transfers,dma_transfers);
                            $finish;
                        end
                    end
                end
            end
        end
    end
endmodule
