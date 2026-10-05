`timescale 1ns/1ps
module tb_mac_interlacer;

reg clk_vga = 0;
reg clk_tv = 0;
always #10 clk_vga = ~clk_vga;
always #20 clk_tv = ~clk_tv;

reg reset = 1;
reg [9:0] source_h = 0;
reg [9:0] source_v = 0;
wire vga_hs = !((source_h >= 10'd656) && (source_h < 10'd752));
wire vga_vs = !((source_v >= 10'd490) && (source_v < 10'd492));
wire vga_de = (source_h < 10'd640) && (source_v < 10'd480);
wire [23:0] vga_rgb = {source_v[7:0], source_h[7:0], 8'h5A};

wire tv_hs;
wire tv_vs;
wire tv_de;
wire [23:0] tv_rgb;

mac_interlacer dut (
	.clk_vga(clk_vga), .clk_tv(clk_tv), .reset(reset),
	.vga_hs(vga_hs), .vga_vs(vga_vs), .vga_de(vga_de), .vga_rgb(vga_rgb),
	.tv_hs(tv_hs), .tv_vs(tv_vs), .tv_de(tv_de), .tv_rgb(tv_rgb)
);

always @(posedge clk_vga) begin
	if (reset) begin
		source_h <= 10'd0;
		source_v <= 10'd0;
	end else begin
		if (source_h == 10'd799) begin
			source_h <= 10'd0;
			source_v <= (source_v == 10'd524) ? 10'd0 : source_v + 10'd1;
		end else begin
			source_h <= source_h + 10'd1;
		end
	end
end

integer tv_cycle = 0;
integer last_vs_fall = -1;
integer field_period;
integer active_lines = 0;
integer completed_fields = 0;
integer expected_field = 1;
integer hs_low_width = 0;
integer vs_start_cycle = -1;
integer errors = 0;
reg prev_tv_vs = 1;
reg prev_tv_hs = 1;
reg prev_tv_de = 0;

always @(posedge clk_tv) begin
	if (!reset) begin
		tv_cycle = tv_cycle + 1;

		if (!tv_hs) hs_low_width = hs_low_width + 1;
		if (prev_tv_hs && tv_hs && hs_low_width != 0) begin
			if (hs_low_width != 70) begin
				$display("FAIL: HS pulse width %0d, expected 70", hs_low_width);
				errors = errors + 1;
			end
			hs_low_width = 0;
		end
		if (!prev_tv_vs && tv_vs) begin
			if (tv_cycle - vs_start_cycle != (expected_field ? 2400 : 2000)) begin
				$display("FAIL: VS pulse width %0d, expected %0d for field %0d",
				tv_cycle - vs_start_cycle, expected_field ? 2400 : 2000, expected_field);
				errors = errors + 1;
			end
			vs_start_cycle = -1;
		end

		if (prev_tv_vs && !tv_vs) begin
			if (last_vs_fall >= 0) begin
				field_period = tv_cycle - last_vs_fall;
				if (field_period != 210000) begin
					$display("FAIL: field period %0d clocks, expected 210000", field_period);
					errors = errors + 1;
				end
				if (active_lines != 240) begin
					$display("FAIL: field had %0d active lines, expected 240", active_lines);
					errors = errors + 1;
				end
				completed_fields = completed_fields + 1;
				expected_field = expected_field ^ 1;
			end
			if (dut.h_cnt !== (expected_field ? 10'd0 : 10'd400)) begin
				$display("FAIL: field %0d starts at h=%0d, expected %0d",
					expected_field, dut.h_cnt, expected_field ? 0 : 400);
				errors = errors + 1;
			end
			vs_start_cycle = tv_cycle;
			last_vs_fall = tv_cycle;
			active_lines = 0;
		end

		if (!prev_tv_de && tv_de) begin
			if (active_lines < 240) begin
				if (tv_rgb[23:16] !== ((2 * active_lines + expected_field) & 255)) begin
					$display("FAIL: active row %0d contains source row %0d, expected %0d",
						active_lines, tv_rgb[23:16], 2 * active_lines + expected_field);
					errors = errors + 1;
				end
				if (tv_rgb[15:8] !== 8'd0) begin
					$display("FAIL: first output pixel has source x=%0d", tv_rgb[15:8]);
					errors = errors + 1;
				end
			end
			active_lines = active_lines + 1;
		end

		prev_tv_vs = tv_vs;
		prev_tv_hs = tv_hs;
		prev_tv_de = tv_de;
	end
end

initial begin
	repeat (8) @(posedge clk_vga);
	reset = 0;
	wait (completed_fields == 2);
	if (errors == 0) $display("PASS: interlaced field timing and line parity");
	else $fatal(1, "FAIL: %0d interlacer checks", errors);
	$finish;
end

initial begin
	#40000000;
	$fatal(1, "FAIL: interlacer test timed out");
end

endmodule