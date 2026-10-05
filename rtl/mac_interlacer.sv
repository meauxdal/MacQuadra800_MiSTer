module mac_interlacer (
	input  wire        clk_vga,
	input  wire        clk_tv,
	input  wire        reset,

	input  wire        vga_hs,
	input  wire        vga_vs,
	input  wire        vga_de,
	input  wire [23:0] vga_rgb,

	output reg         tv_hs,
	output reg         tv_vs,
	output reg         tv_de,
	output reg  [23:0] tv_rgb
);

localparam H_TOTAL = 800;
localparam H_SYNC = 70;
localparam H_BACK = 80;
localparam H_ACTIVE = 640;
localparam H_ACTIVE_START = H_SYNC + H_BACK;
localparam H_HALF = H_TOTAL / 2;
localparam V_SYNC = 3;
localparam V_ACTIVE_START = 17;
localparam V_ACTIVE = 240;

(* ramstyle = "M10K" *) reg [23:0] line_buffer_0 [0:H_ACTIVE-1];
(* ramstyle = "M10K" *) reg [23:0] line_buffer_1 [0:H_ACTIVE-1];

reg vga_hs_prev;
reg vga_vs_prev;
reg vga_de_prev;
reg input_field_odd;
reg input_field_toggle;
reg seen_active_line;
reg [9:0] active_line;
reg capture_line;
reg write_bank;
reg [9:0] write_ptr;

wire vs_rise = vga_vs && !vga_vs_prev;
wire de_rise = vga_de && !vga_de_prev;
wire [9:0] next_active_line = seen_active_line ? active_line + 10'd1 : 10'd0;
wire select_new_line = (next_active_line[0] == input_field_odd);

always @(posedge clk_vga) begin
	if (reset) begin
		vga_hs_prev <= 1'b1;
		vga_vs_prev <= 1'b1;
		vga_de_prev <= 1'b0;
		input_field_odd <= 1'b0;
		input_field_toggle <= 1'b0;
		seen_active_line <= 1'b0;
		active_line <= 10'd0;
		capture_line <= 1'b0;
		write_bank <= 1'b0;
		write_ptr <= 10'd0;
	end else begin
		vga_hs_prev <= vga_hs;
		vga_vs_prev <= vga_vs;
		vga_de_prev <= vga_de;

		if (vs_rise) begin
			input_field_odd <= ~input_field_odd;
			input_field_toggle <= ~input_field_toggle;
			seen_active_line <= 1'b0;
			active_line <= 10'd0;
			capture_line <= 1'b0;
			write_bank <= 1'b0;
			write_ptr <= 10'd0;
		end else if (de_rise) begin
			active_line <= next_active_line;
			seen_active_line <= 1'b1;
			capture_line <= select_new_line;
			write_ptr <= select_new_line ? 10'd1 : 10'd0;
			if (select_new_line) begin
				if (write_bank) line_buffer_1[0] <= vga_rgb;
				else           line_buffer_0[0] <= vga_rgb;
			end
		end else if (vga_de && capture_line && write_ptr < H_ACTIVE) begin
			if (write_bank) line_buffer_1[write_ptr] <= vga_rgb;
			else           line_buffer_0[write_ptr] <= vga_rgb;
			write_ptr <= write_ptr + 10'd1;
		end else if (!vga_de && vga_de_prev) begin
			if (capture_line) write_bank <= ~write_bank;
			capture_line <= 1'b0;
			write_ptr <= 10'd0;
		end
	end
end

reg field_sync_meta;
reg field_sync;
reg field_sync_prev;
reg field_locked;
reg output_field_odd;
reg read_bank;
reg [9:0] h_cnt;
reg [8:0] v_cnt;
reg [9:0] read_ptr;

wire active_pixel =
	(h_cnt >= H_ACTIVE_START) &&
	(h_cnt < H_ACTIVE_START + H_ACTIVE) &&
	(v_cnt >= V_ACTIVE_START) &&
	(v_cnt < V_ACTIVE_START + V_ACTIVE);
wire [8:0] next_v_cnt = (h_cnt == H_TOTAL - 1) ? v_cnt + 9'd1 : v_cnt;

always @(posedge clk_tv) begin
	if (reset) begin
		field_sync_meta <= 1'b0;
		field_sync <= 1'b0;
		field_sync_prev <= 1'b0;
		field_locked <= 1'b0;
		output_field_odd <= 1'b0;
		read_bank <= 1'b0;
		h_cnt <= 10'd0;
		v_cnt <= 9'd0;
		read_ptr <= 10'd0;
		tv_hs <= 1'b1;
		tv_vs <= 1'b1;
		tv_de <= 1'b0;
		tv_rgb <= 24'd0;
	end else begin
		field_sync_meta <= input_field_toggle;
		field_sync <= field_sync_meta;
		field_sync_prev <= field_sync;

		if (field_sync != field_sync_prev) begin
			field_locked <= 1'b1;
			output_field_odd <= ~output_field_odd;
			h_cnt <= output_field_odd ? H_HALF : 10'd0;
			v_cnt <= 9'd0;
			read_bank <= 1'b0;
			read_ptr <= 10'd0;
			tv_hs <= 1'b1;
			tv_vs <= 1'b0;
			tv_de <= 1'b0;
			tv_rgb <= 24'd0;
		end else if (!field_locked) begin
			tv_hs <= 1'b1;
			tv_vs <= 1'b1;
			tv_de <= 1'b0;
			tv_rgb <= 24'd0;
		end else begin
			if (h_cnt == H_TOTAL - 1) begin
				h_cnt <= 10'd0;
				v_cnt <= v_cnt + 9'd1;
			end else begin
				h_cnt <= h_cnt + 10'd1;
			end

			tv_hs <= !(h_cnt < H_SYNC);
			tv_vs <= !(next_v_cnt < V_SYNC);
			tv_de <= active_pixel;
			if (active_pixel) begin
				tv_rgb <= read_bank ? line_buffer_1[read_ptr] : line_buffer_0[read_ptr];
				if (h_cnt == H_ACTIVE_START + H_ACTIVE - 1) begin
					read_bank <= ~read_bank;
					read_ptr <= 10'd0;
				end else begin
					read_ptr <= read_ptr + 10'd1;
				end
			end else begin
				tv_rgb <= 24'd0;
				read_ptr <= 10'd0;
			end
		end
	end
end

endmodule