// Short native CPU tests on quadra800 + sdram_beat32 + sdram.sv.
// The SDRAM chip model comes from verilator/tb_sdram.sv; no guest OS boot.
`timescale 1ps/1ps

module tb_native_platform;

localparam integer TR = 5050;              // clk_ram half period (99.0 MHz)
localparam integer TS = 3*TR;              // clk_sys half period (33.0 MHz)

reg clk_ram = 0, clk_sys = 0;
always #TR clk_ram = ~clk_ram;
always #TS clk_sys = ~clk_sys;

reg sdram_init = 1;
reg nreset     = 0;

//----------------------------------------------------------------------------
// the machine
//----------------------------------------------------------------------------
wire        mem_req, mem_write;
wire [31:2] mem_addr;
wire  [3:0] mem_be;
wire [31:0] mem_wdata;
wire  [1:0] mem_memsel;
wire [31:0] mem_rdata;
wire        mem_ack;
reg  [31:0] mem_rdata_r = 0;
reg         mem_ack_r   = 0;
wire        mem_wp_valid;
wire [31:2] mem_wp_addr;
wire  [3:0] mem_wp_be;
wire [31:0] mem_wp_data;
wire        sdr_wq_room, sdr_line_valid, sdr_line_pending;
wire [26:4] sdr_line_tag, sdr_line_pending_tag;
wire [127:0] sdr_line_data;
wire        sdr_ack;
wire [31:0] sdr_rdata;
wire        dbg_berr, debug_fault, debug_halted;
wire [31:0] dbg_berr_addr;
wire [255:0] debug_status;
reg [2:0] img_mounted=0, io_ack=0;
wire [2:0] io_rd, io_wr;
wire [31:0] io_lba;
wire [5:0] io_blk_cnt;
reg [63:0] img_size=0;
reg [12:0] sd_buff_addr=0;
reg [15:0] sd_buff_dout=0;
wire [15:0] sd_buff_din;
reg sd_buff_wr=0;

wire mem_is_ram  = (mem_memsel == 2'd0);
wire mem_is_rom  = (mem_memsel == 2'd1);
wire mem_is_vram = !mem_is_ram && !mem_is_rom;

assign mem_ack   = mem_ack_r | sdr_ack;
assign mem_rdata = sdr_ack ? sdr_rdata : mem_rdata_r;

quadra800 #(.RAM_ADDR_BITS(27), .CDROM(1), .SONIC(0)) dut (
	.clk(clk_sys), .nreset(nreset), .ce(1'b1),
	.clk_vid(1'b0), .nreset_vid(1'b0),
	.ram_cfg(2'd0), .mon_12in(1'b0),
	.mem_req(mem_req), .mem_write(mem_write), .mem_addr(mem_addr), .mem_be(mem_be),
	.mem_wdata(mem_wdata), .mem_memsel(mem_memsel), .mem_rdata(mem_rdata), .mem_ack(mem_ack),
	.mem_wp_valid(mem_wp_valid), .mem_wp_addr(mem_wp_addr), .mem_wp_be(mem_wp_be),
	.mem_wp_data(mem_wp_data), .mem_wq_room(sdr_wq_room),
	.mem_line_valid(sdr_line_valid), .mem_line_tag(sdr_line_tag), .mem_line_data(sdr_line_data),
	.mem_rom_line_valid(1'b0), .mem_rom_line_tag(16'd0), .mem_rom_line_data(128'd0),
	.mem_line_pending(sdr_line_pending), .mem_line_pending_tag(sdr_line_pending_tag),
	.vid_addr(), .vid_rdata(32'd0), .vid_stride(),
	.VGA_R(), .VGA_G(), .VGA_B(), .VGA_HS(), .VGA_VS(), .VGA_HB(), .VGA_VB(), .CE_PIXEL(),
	.AUDIO_L(), .AUDIO_R(), .cd_snd_l(), .cd_snd_r(),
	.img_mounted(img_mounted), .img_size(img_size), .io_lba(io_lba), .io_blk_cnt(io_blk_cnt), .io_rd(io_rd), .io_wr(io_wr),
	.io_ack(io_ack), .sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout), .sd_buff_din(sd_buff_din), .sd_buff_wr(sd_buff_wr),
	.ps2_key(11'd0), .ps2_mouse(25'd0), .timestamp(33'd0),
	.scc_rxd_a(1'b1), .scc_txd_a(), .scc_cts_a(1'b1), .scc_rts_a(), .scc_rxd_b(1'b1), .scc_txd_b(),
	.dbg_berr(dbg_berr), .dbg_berr_addr(dbg_berr_addr), .dbg_overlay(),
	.debug_status(debug_status), .debug_status2(), .debug_fault(debug_fault), .debug_halted(debug_halted),
	.eth_ena(1'b0), .dbg_sw(3'd0),
	.eth_mem_addr(), .eth_mem_rd(), .eth_mem_we(), .eth_mem_wdata(),
	.eth_mem_accept(1'b0), .eth_mem_rvalid(1'b0), .eth_mem_rdata(64'd0)
);

// Use the normal ROM reset/overlay path; no force of internal state.

//----------------------------------------------------------------------------
// SDRAM: the bridge and controller from $TREE, two ranks of chip model
//----------------------------------------------------------------------------
wire [15:0] SDRAM_DQ;
wire [12:0] SDRAM_A;
wire        SDRAM_DQML, SDRAM_DQMH;
wire  [1:0] SDRAM_BA;
wire        SDRAM_nCS, SDRAM_nWE, SDRAM_nRAS, SDRAM_nCAS, SDRAM_CKE, SDRAM_CLK;

sdram_beat32 sdr (
	.init(sdram_init), .clk_sys(clk_sys), .clk_ram(clk_ram),
	.req(mem_req && mem_is_ram), .we(mem_write), .addr(mem_addr[26:2]), .be(mem_be),
	.wdata(mem_wdata), .ack(sdr_ack), .rdata(sdr_rdata), .busy(),
	.line_valid_o(sdr_line_valid), .line_tag_o(sdr_line_tag), .line_data_o(sdr_line_data),
	.line_pending_o(sdr_line_pending), .line_pending_tag_o(sdr_line_pending_tag),
	.wp_valid(mem_wp_valid), .wp_addr(mem_wp_addr[26:2]), .wp_be(mem_wp_be),
	.wp_data(mem_wp_data), .wq_room(sdr_wq_room),
	.SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
	.SDRAM_BA(SDRAM_BA), .SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE), .SDRAM_nRAS(SDRAM_nRAS),
	.SDRAM_nCAS(SDRAM_nCAS), .SDRAM_CKE(SDRAM_CKE), .SDRAM_CLK(SDRAM_CLK)
);

sdram_model chip (
	.clk(SDRAM_CLK), .cke(SDRAM_CKE), .nCS(SDRAM_nCS),
	.nRAS(SDRAM_nRAS), .nCAS(SDRAM_nCAS), .nWE(SDRAM_nWE),
	.ba(SDRAM_BA), .a(SDRAM_A), .dqmh(SDRAM_DQMH), .dqml(SDRAM_DQML), .dq(SDRAM_DQ)
);
sdram_model chip_hi (
	.clk(SDRAM_CLK), .cke(SDRAM_CKE), .nCS(~SDRAM_nCS),
	.nRAS(SDRAM_nRAS), .nCAS(SDRAM_nCAS), .nWE(SDRAM_nWE),
	.ba(SDRAM_BA), .a(SDRAM_A), .dqmh(SDRAM_DQMH), .dqml(SDRAM_DQML), .dq(SDRAM_DQ)
);

// byte address -> chip cell key, sdram.sv's decode (bank B[24:23], row
// B[22:10], col {B[25], B[9:2], half}); the high half-word of a longword is
// {byte+0, byte+1}.  All of the 32 MB image sits in rank 0 (B[26] = 0).
function automatic int sdcell(input int b, input bit lo);
	sdcell = {7'd0, b[24:23], b[22:10], b[25], b[9:2], lo};
endfunction

//----------------------------------------------------------------------------
// ROM (DDR3 on hardware) and VRAM (on-chip BRAM) beats, as MacQuadra800.sv
//----------------------------------------------------------------------------
reg [7:0] rom [0:1048575];
integer   romlat = 6, rom_wait = -1;
reg       vram_ph = 0;
longint   rom_reads = 0, rom_reads_loop = 0, vram_beats = 0;
reg       in_loop = 0;

always @(posedge clk_sys) begin
	mem_ack_r <= 0;
	if (mem_req && !mem_ack && mem_is_vram) begin
		if (!vram_ph) vram_ph <= 1;
		else begin vram_ph <= 0; mem_rdata_r <= 0; mem_ack_r <= 1; vram_beats++; end
	end
	if (mem_req && !mem_ack && mem_is_rom) begin
		if (mem_write) mem_ack_r <= 1;
		else if (rom_wait < 0) rom_wait = romlat;
		else if (rom_wait <= 1) begin
			mem_rdata_r <= {rom[{mem_addr[19:2],2'd0}], rom[{mem_addr[19:2],2'd1}],
			                rom[{mem_addr[19:2],2'd2}], rom[{mem_addr[19:2],2'd3}]};
			mem_ack_r <= 1;
			rom_wait = -1;
			rom_reads++; if (in_loop) rom_reads_loop++;
		end
		else rom_wait = rom_wait - 1;
	end
end


reg [7:0] img [0:65535];
import "DPI-C" function int platform_image_open(input string path);
import "DPI-C" function int platform_image_read(input int slot, input int unsigned lba, input int bytes);
import "DPI-C" function int platform_image_byte(input int offset);
import "DPI-C" function void platform_window_word(input int offset, input int value);
import "DPI-C" function void platform_window_write(input int unsigned lba);
string image_path, trace_path;
integer host_state=0, host_delay=40, host_wait=0, host_slot=0, host_words=0, host_i=0;
integer trace_fd=0, host_requests=0;
integer dest=0, expected_bytes=0, expected_offset=0, image_bytes=0;
integer scsi_mode=0;
reg [31:0] host_lba=0;
reg [7:0] expected [0:16383];
// Same HPS protocol as tb_ncr53c96 / sim_blkdevice: ack leads word zero,
// remains high through all sd_blk_cnt+1 blocks, then falls after last word.
always @(posedge clk_sys) if(nreset && scsi_mode) begin
    sd_buff_wr <= 0;
    case(host_state)
    0: if (|io_rd || |io_wr) begin
        host_slot = (io_rd[0]|io_wr[0]) ? 0 : (io_rd[1]|io_wr[1]) ? 1 : 2;
        host_lba=io_lba;
        host_words = (int'(io_blk_cnt)+1)*256;
        if (|io_wr && (host_slot!=2 || io_lba<32'h7d000000 || io_lba>=32'h7e000000))
            $fatal(1,"unexpected image write");
        if((|io_rd) && platform_image_read(host_slot,io_lba,host_words*2)!=host_words*2)
            $fatal(1,"invalid image request lba=%h words=%d",io_lba,host_words);
        $fdisplay(trace_fd,"H %0d %0d %08x %0d",|io_wr,host_slot,io_lba,io_blk_cnt);
        host_requests <= host_requests+1;
        host_wait <= host_delay; host_state <= (|io_rd) ? 1 : 4;
    end
    1: if(host_wait!=0) host_wait<=host_wait-1;
       else begin io_ack[host_slot]<=1; host_i<=0; host_state<=2; end
    2: if(host_i<host_words) begin
        sd_buff_addr<=13'(host_i);
        sd_buff_dout<=16'((platform_image_byte(host_i*2)<<8)|platform_image_byte(host_i*2+1));
        sd_buff_wr<=1; host_i<=host_i+1;
    end else begin io_ack<=0; host_state<=3; end
    3: host_state<=0;
    4: if(host_wait!=0) host_wait<=host_wait-1;
       else begin io_ack[host_slot]<=1; host_i<=0; host_state<=5; end
    5: begin
        // Registered address plus registered target-buffer read: capture i-2.
        if(host_i>=2 && host_i<258) begin
            platform_window_word(host_i-2,int'(sd_buff_din));
            $fdisplay(trace_fd,"H W %0d %04x",host_i-2,sd_buff_din);
        end
        sd_buff_addr<=13'(host_i);
        host_i<=host_i+1;
        if(host_i==258) begin
            platform_window_write(host_lba);
            io_ack<=0; host_state<=3;
        end
    end
    endcase
    // Completed physical CPU transactions; polling is retained in the raw
    // trace, normalized by the runner only when it has no device side effect.
    if(dut.bus_req && dut.bus_ack && dut.bus_addr[31:20]==12'h50f)
        $fdisplay(trace_fd,"B %0d %0d %08x %08x",dut.bus_write,dut.bus_size,
                  dut.bus_addr,dut.bus_write ? dut.bus_wdata : dut.bus_rdata);
    if(dbg_berr) $fatal(1,"unexpected bus error address=%h",dbg_berr_addr);
end
string path;
integer fd,count,i;
integer cycles=0, failures=0, done_wait=0;
initial begin
    if($value$plusargs("image=%s",image_path)) begin
        scsi_mode=1;
        image_bytes=platform_image_open(image_path);
        if(image_bytes<=0) $fatal(1,"image open");
        if(!$value$plusargs("trace=%s",trace_path)) $fatal(1,"missing trace");
        trace_fd=$fopen(trace_path,"w");
        if(!$value$plusargs("dest=%d",dest) || !$value$plusargs("bytes=%d",expected_bytes) ||
           !$value$plusargs("offset=%d",expected_offset)) $fatal(1,"missing expected range");
        if(expected_bytes>16384 || expected_bytes<=0) $fatal(1,"expected range too large");
        if(platform_image_read(0,32'(expected_offset/512),expected_bytes)!=expected_bytes) $fatal(1,"expected read");
        for(i=0;i<expected_bytes;i++) expected[i]=8'(platform_image_byte(i));
        if(!$value$plusargs("host_delay=%d",host_delay)) host_delay=40;
    end
    if (!$value$plusargs("prog=%s",path)) $fatal(1,"missing +prog");
    fd=$fopen(path,"rb"); if(!fd) $fatal(1,"program open");
    count=$fread(img,fd); $fclose(fd);
    for(i=0;i<65536;i+=2) chip.mem[sdcell(i,i[1])]={img[i],img[i+1]};
    for(i=0;i<65536;i++) rom[i]=img[i];
    if($test$plusargs("ram_program")) begin
        // ROM reset trampoline clears the real overlay, then runs the
        // unmodified upstream program from its preloaded RAM addresses.
        rom[4]=8'h40; rom[5]=8'h8f; rom[6]=8'hf0; rom[7]=8'h00;
        rom['hff000]=8'h4e; rom['hff001]=8'hf9;
        for(i=0;i<4;i++) rom['hff002+i]=img[4+i];
    end
    repeat(8) @(negedge clk_sys); sdram_init=0;
    wait(sdr.sdram.state==5); repeat(50) @(negedge clk_sys); nreset=1;
    if(scsi_mode) begin
        img_size=image_bytes;
        img_mounted=1; repeat(2) @(negedge clk_sys); img_mounted=0;
        repeat(2) @(negedge clk_sys);
        img_mounted=4; repeat(2) @(negedge clk_sys); img_mounted=0;
    end
end
always @(posedge clk_sys) if(nreset) begin
    cycles<=cycles+1;
    if(cycles>3000000) $fatal(1,"platform timeout status=%h",debug_status);
    if(debug_fault || debug_halted) $fatal(1,"unexpected CPU fault/halt status=%h",debug_status);
    if(dut.bus_req && dut.bus_ack && dut.bus_write && dut.bus_addr==32'hf102) begin
        if(dut.bus_wdata!=32'h600d) $fatal(1,"program failed status=%h",debug_status);
        done_wait<=1;
    end
    if(done_wait!=0) begin
        done_wait<=done_wait+1;
        if(done_wait==64) begin
            if(chip.errors+chip_hi.errors!=0) $fatal(1,"SDRAM protocol errors");
            if(scsi_mode) begin
                if(host_requests==0) $fatal(1,"no host requests");
                for(integer b=0;b<expected_bytes;b++) begin
                    if((b+dest)&1) count=chip.mem[sdcell((dest+b)&~3,((dest+b)&2)!=0)] & 255;
                    else count=chip.mem[sdcell((dest+b)&~3,((dest+b)&2)!=0)] >> 8;
                    $fdisplay(trace_fd,"R %08x %02x",dest+b,count);
                    if(count!=int'(expected[b])) $fatal(1,"RAM byte %h got=%02h expected=%02h",dest+b,count,expected[b]);
                end
                $fclose(trace_fd);
                $display("PASS SCSI bytes=%0d host_requests=%0d",expected_bytes,host_requests);
            end
            $display("PASS native CPU + real Q800 bus32/service + SDRAM bridge/controller program test cycles=%0d protocol_errors=%0d",cycles,chip.errors+chip_hi.errors);
            $finish;
        end
    end
end
endmodule
