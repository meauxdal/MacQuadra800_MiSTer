// Real DAFB scanout/CLUT tap, with a zero-filled registered VRAM fixture.
module tv_dafb_pipeline (
    input wire clk_source, clk_mem, clk_tv, reset_tv, reset_registers, reset_source, mon_12in,
    input wire reg_sel,
    input wire [7:0] reg_addr,
    input wire [31:0] reg_wdata,
    output wire reg_ack,
    output wire native_de, native_line, native_frame, native_ce,
    output wire [23:0] native_rgb,
    output wire [9:0] native_width,
    output wire [8:0] native_height,
    output wire [28:0] tag_raw, tag_out,
    output wire [23:0] rgb_raw, component,
    output wire [27:0] address,
    output wire [7:0] burstcount,
    output wire [127:0] writedata,
    output wire [15:0] byteenable,
    output wire read, write,
    input wire waitrequest, readdatavalid,
    input wire [127:0] readdata,
    output wire [31:0] published, overflows, underruns
);
wire hb,vb;
assign native_de=!(hb||vb);
dafb source (
    .clk(clk_mem), .nreset(!reset_registers), .ce(1'b1),
    .clk_vid(clk_source), .nreset_vid(!reset_source), .mon_12in(mon_12in),
    .sel(reg_sel), .write(1'b1), .addr(reg_addr), .wdata(reg_wdata), .rdata(), .ack(reg_ack),
    .vbl_irq(), .vid_addr(), .vid_rdata(32'd0), .vid_stride(),
    .vga_r(native_rgb[23:16]), .vga_g(native_rgb[15:8]), .vga_b(native_rgb[7:0]),
    .vga_hs(), .vga_vs(), .vga_hb(hb), .vga_vb(vb), .ce_pixel(native_ce),
    .native_line_start(native_line), .native_frame_start(native_frame),
    .native_width(native_width), .native_height(native_height)
);
tv_frame_pipeline pipeline (
    .clk_source(clk_source), .source_reset(reset_source), .source_ce(native_ce), .source_de(native_de),
    .source_line(native_line), .source_frame(native_frame), .source_width(native_width),
    .source_height(native_height), .source_rgb(native_rgb),
    .clk_mem(clk_mem), .inhibit(1'b0), .clk_tv(clk_tv), .reset_tv(reset_tv),
    .a_address(28'd0), .a_burstcount(8'd1), .a_writedata(128'd0), .a_byteenable(16'd0),
    .a_read(1'b0), .a_write(1'b0), .a_waitrequest(), .a_readdatavalid(), .a_readdata(),
    .address(address), .burstcount(burstcount), .writedata(writedata), .byteenable(byteenable),
    .read(read), .write(write), .waitrequest(waitrequest), .readdatavalid(readdatavalid), .readdata(readdata),
    .tag_raw(tag_raw), .tag_out(tag_out), .rgb_raw(rgb_raw), .component(component),
    .published(published), .dropped(), .repeated(), .overflows(overflows), .underruns(underruns)
);
endmodule
