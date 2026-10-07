// Simulation integration wrapper; not yet connected to sys_top or DAC pins.
module tv525_diagnostic (
    input  wire clk,
    input  wire reset,
    input  wire [2:0] pattern,
    input  wire [1:0] geometry,
    output wire csync_n, hsync_n, vsync_n,
    output wire picture_de, pixel_ce, image_de,
    output wire [9:0] canvas_x,
    output wire [8:0] canvas_y,
    output wire field_id, frame_start, field_start, line_start, halfline_start,
    output wire [10:0] h_sample,
    output wire [9:0] line_number,
    output wire [23:0] rgb
);
tv525_timing timing (
    .clk(clk), .reset(reset), .csync_n(csync_n), .hsync_n(hsync_n),
    .vsync_n(vsync_n), .picture_de(picture_de), .pixel_ce(pixel_ce),
    .canvas_x(canvas_x), .canvas_y(canvas_y), .field_id(field_id),
    .frame_start(frame_start), .field_start(field_start), .line_start(line_start),
    .halfline_start(halfline_start), .h_sample(h_sample), .line_number(line_number)
);
tv_test_pattern picture (
    .picture_de(picture_de), .canvas_x(canvas_x), .canvas_y(canvas_y),
    .field_id(field_id), .pattern(pattern), .geometry(geometry),
    .rgb(rgb), .image_de(image_de)
);
endmodule
