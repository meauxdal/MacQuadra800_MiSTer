// Standalone diagnostic -> TV OSD -> component -> digital pin adapter.
// Not in production Quartus filelists. All pixels and tags run on clk_tv.
// Resets must be asserted together and released synchronously in each domain.
module tv525_output (
    input wire clk_tv, reset_tv, clk_sys, reset_sys,
    input wire [2:0] pattern,
    input wire [1:0] geometry,
    input wire io_osd, io_strobe,
    input wire [15:0] io_din,
    input wire av_dis, video_disable,
    output wire osd_status,
    output wire [23:0] component, composed_rgb,
    output wire [28:0] tag_raw, tag_composed, tag_out,
    output wire [23:0] rgb_raw,
    output wire drive_enable,
    output wire [5:0] dac_r, dac_g, dac_b,
    output wire [1:0] low_r, low_g, low_b,
    output wire hs_n, vs_n
);
wire cs, hs, vs, de, ce, field_id, frame, field_start, line_start, half_start;
wire [9:0] x;
wire [8:0] y;
wire [10:0] unused_h_sample;
wire [9:0] unused_line_number;
wire unused_image_de;
tv525_timing timing (
    .clk(clk_tv), .reset(reset_tv), .csync_n(cs), .hsync_n(hs), .vsync_n(vs),
    .picture_de(de), .pixel_ce(ce), .canvas_x(x), .canvas_y(y),
    .field_id(field_id), .frame_start(frame), .field_start(field_start),
    .line_start(line_start), .halfline_start(half_start),
    .h_sample(unused_h_sample), .line_number(unused_line_number)
);
// Keep diagnostic controls steady for each pair. Future platform controls
// require a separate coherent frame-boundary mailbox, as the OSD does.
tv_test_pattern picture (
    .picture_de(de), .canvas_x(x), .canvas_y(y), .field_id(field_id),
    .pattern(pattern), .geometry(geometry), .rgb(rgb_raw), .image_de(unused_image_de)
);
// 28:26 sync; 25 DE; 24 CE; 23 parity; 22 frame; 21 field;
// 20 line; 19 half-line; 18:9 x; 8:0 y. One tag travels with every sample.
assign tag_raw = {cs,hs,vs,de,ce,field_id,frame,field_start,line_start,half_start,x,y};
tv_osd osd (
    .clk_sys(clk_sys), .reset_sys(reset_sys), .io_osd(io_osd),
    .io_strobe(io_strobe), .io_din(io_din), .osd_status(osd_status),
    .clk_tv(clk_tv), .reset_tv(reset_tv), .frame_start(frame),
    .canvas_x(x), .canvas_y(y), .picture_de(de), .rgb(rgb_raw),
    .tag_in(tag_raw), .rgb_out(composed_rgb), .tag_out(tag_composed)
);
tv_component converter (
    .clk(clk_tv), .reset(reset_tv), .rgb(composed_rgb),
    .picture_de(tag_composed[25]), .tag_in(tag_composed),
    .component(component), .tag_out(tag_out)
);
tv_component_pins pins (
    .component(component), .csync_n(tag_out[28]), .av_dis(av_dis),
    .video_disable(video_disable), .drive_enable(drive_enable),
    .dac_r(dac_r), .dac_g(dac_g), .dac_b(dac_b),
    .low_r(low_r), .low_g(low_g), .low_b(low_b), .hs_n(hs_n), .vs_n(vs_n)
);
endmodule
