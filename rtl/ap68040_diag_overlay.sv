// Read-only CPU observer. Enabling diagnostics clears the capture; guest
// resets do not. Snapshot transfer to video uses a bundled-data handshake.
module ap68040_diag_overlay (
    input logic clk_sys, clk_vid,
    input logic enable, machine_reset,
    input logic [255:0] cpu_status,
    input logic [127:0] cpu_status2,
    input logic ce_pixel, hblank, vblank,
    output logic box, ink
);
    typedef struct packed {
        logic [15:0] resets, rom_entries, faults;
        logic [31:0] pc, bus_addr, state_bits, reset_pc;
        logic [95:0] latest, first_ram;
        logic ram_seen;
        logic [63:0] pointer0, pointer1, pointer2;
        logic [2:0] pointer_valid;
        logic pointer_frozen;
    } snapshot_t;
    snapshot_t captured = '0, held = '0, shown = '0;
    logic enable_q = 0, reset_q = 0, rom_q = 0;
    logic request_v = 0, acknowledge_s = 0;
    (* async_reg = "true" *) logic [1:0] request_s = 0, acknowledge_v = 0;
    (* async_reg = "true" *) logic [1:0] enable_v = 0;
    logic pending_v = 0;
    logic first_valid = 0;
    wire native_cpu = cpu_status[255:240] == 16'hA040;
    wire event_valid = native_cpu && cpu_status[239];
    wire retired = native_cpu && cpu_status[238];
    wire [95:0] event_info = cpu_status[223:128];
    wire [7:0] vector_number = event_info[95:88];
    wire selected_fault = vector_number == 2 || vector_number == 3 ||
                          vector_number == 4 || vector_number == 8 || vector_number == 14;
    wire [31:0] retire_pc = cpu_status[95:64];
    wire rom_entry = retired && (retire_pc == 32'h0000008c || retire_pc == 32'h4080008c);
    wire pointer_fault = event_valid && vector_number == 2 &&
                         event_info[79:48] == 32'h408253cc;
    wire load_valid = native_cpu && cpu_status2[96];

    always_ff @(posedge clk_sys) begin
        enable_q <= enable;
        reset_q <= machine_reset;
        rom_q <= rom_entry;
        request_s <= {request_s[0], request_v};
        if (request_s[1] != acknowledge_s) begin
            held <= captured;
            acknowledge_s <= request_s[1];
        end
        if (enable && !enable_q) begin
            captured <= '0;
            first_valid <= 0;
        end else if (enable) begin
            captured.pc <= cpu_status[31:0];
            captured.bus_addr <= cpu_status[127:96];
            captured.state_bits <= {machine_reset, cpu_status[62:32]};
            // The observed retail 8.1 failure follows these three MOVEA
            // loads. Keep one invocation's logical EAs/results, including
            // cache hits, and freeze at the actual failing dereference.
            if (!machine_reset && !captured.pointer_frozen) begin
                if (load_valid) begin
                    case (cpu_status2[95:64])
                        32'h408253c2: begin
                            captured.pointer0 <= cpu_status2[63:0];
                            captured.pointer1 <= '0;
                            captured.pointer2 <= '0;
                            captured.pointer_valid <= 3'b001;
                        end
                        32'h408253c6: if (captured.pointer_valid == 3'b001) begin
                            captured.pointer1 <= cpu_status2[63:0];
                            captured.pointer_valid <= 3'b011;
                        end
                        32'h408253c8: if (captured.pointer_valid == 3'b011) begin
                            captured.pointer2 <= cpu_status2[63:0];
                            captured.pointer_valid <= 3'b111;
                        end
                        default: ;
                    endcase
                end
                if (pointer_fault) captured.pointer_frozen <= 1;
            end
            if (machine_reset && !reset_q) begin
                captured.resets <= captured.resets + 1'b1;
                captured.reset_pc <= cpu_status[31:0];
            end
            if (rom_entry && !rom_q) captured.rom_entries <= captured.rom_entries + 1'b1;
            if (retired && !machine_reset && retire_pc >= 32'h10000 &&
                retire_pc[31:27] == 0) captured.ram_seen <= 1;
            if (event_valid && selected_fault && !machine_reset) begin
                captured.faults <= captured.faults + 1'b1;
                captured.latest <= event_info;
                if (captured.ram_seen && !first_valid) begin
                    captured.first_ram <= event_info;
                    first_valid <= 1;
                end
            end
        end
    end

    logic hb_q = 1, vb_q = 1;
    logic [10:0] x = 0, y = 0;
    always_ff @(posedge clk_vid) begin
        enable_v <= {enable_v[0], enable};
        acknowledge_v <= {acknowledge_v[0], acknowledge_s};
        // held is stable before the synchronized acknowledge arrives and
        // stays stable until the next video request, once per frame.
        if (pending_v && acknowledge_v[1] == request_v) begin
            shown <= held;
            pending_v <= 0;
        end
        if (ce_pixel) begin
            hb_q <= hblank;
            vb_q <= vblank;
            if (hblank) x <= 0; else x <= x + 1'b1;
            if (vblank) y <= 0;
            else if (hblank && !hb_q) y <= y + 1'b1;
            if (vblank && !vb_q && !pending_v) begin
                request_v <= !request_v;
                pending_v <= 1;
            end
        end
    end

    function automatic [7:0] hex_digit(input logic [3:0] n);
        return n < 10 ? 8'h30 + {4'd0,n} : 8'h41 + {4'd0,n} - 8'd10;
    endfunction
    function automatic [63:0] hex32(input logic [31:0] n);
        for (int i=0; i<8; i++) hex32[63-8*i-:8] = hex_digit(n[31-4*i-:4]);
    endfunction
    function automatic [31:0] hex16(input logic [15:0] n);
        for (int i=0; i<4; i++) hex16[31-8*i-:8] = hex_digit(n[15-4*i-:4]);
    endfunction
    function automatic [15:0] hex8(input logic [7:0] n);
        return {hex_digit(n[7:4]),hex_digit(n[3:0])};
    endfunction
    function automatic [4:0] glyph(input logic [7:0] c, input logic [2:0] row);
        logic [34:0] p;
        case (c)
            "0": p={5'b01110,5'b10001,5'b10011,5'b10101,5'b11001,5'b10001,5'b01110};
            "1": p={5'b00100,5'b01100,5'b00100,5'b00100,5'b00100,5'b00100,5'b01110};
            "2": p={5'b01110,5'b10001,5'b00001,5'b00010,5'b00100,5'b01000,5'b11111};
            "3": p={5'b11110,5'b00001,5'b00001,5'b01110,5'b00001,5'b00001,5'b11110};
            "4": p={5'b00010,5'b00110,5'b01010,5'b10010,5'b11111,5'b00010,5'b00010};
            "5": p={5'b11111,5'b10000,5'b10000,5'b11110,5'b00001,5'b00001,5'b11110};
            "6": p={5'b01110,5'b10000,5'b10000,5'b11110,5'b10001,5'b10001,5'b01110};
            "7": p={5'b11111,5'b00001,5'b00010,5'b00100,5'b01000,5'b01000,5'b01000};
            "8": p={5'b01110,5'b10001,5'b10001,5'b01110,5'b10001,5'b10001,5'b01110};
            "9": p={5'b01110,5'b10001,5'b10001,5'b01111,5'b00001,5'b00001,5'b01110};
            "A": p={5'b01110,5'b10001,5'b10001,5'b11111,5'b10001,5'b10001,5'b10001};
            "B": p={5'b11110,5'b10001,5'b10001,5'b11110,5'b10001,5'b10001,5'b11110};
            "C": p={5'b01111,5'b10000,5'b10000,5'b10000,5'b10000,5'b10000,5'b01111};
            "D": p={5'b11110,5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b11110};
            "E": p={5'b11111,5'b10000,5'b10000,5'b11110,5'b10000,5'b10000,5'b11111};
            "F": p={5'b11111,5'b10000,5'b10000,5'b11110,5'b10000,5'b10000,5'b10000};
            "L": p={5'b10000,5'b10000,5'b10000,5'b10000,5'b10000,5'b10000,5'b11111};
            "M": p={5'b10001,5'b11011,5'b10101,5'b10101,5'b10001,5'b10001,5'b10001};
            "O": p={5'b01110,5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b01110};
            "P": p={5'b11110,5'b10001,5'b10001,5'b11110,5'b10000,5'b10000,5'b10000};
            "R": p={5'b11110,5'b10001,5'b10001,5'b11110,5'b10100,5'b10010,5'b10001};
            "S": p={5'b01111,5'b10000,5'b10000,5'b01110,5'b00001,5'b00001,5'b11110};
            "T": p={5'b11111,5'b00100,5'b00100,5'b00100,5'b00100,5'b00100,5'b00100};
            "U": p={5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b01110};
            default: p='0;
        endcase
        return row < 7 ? p[34-5*row-:5] : 5'd0;
    endfunction

    logic [319:0] line_text;
    logic [7:0] character;
    logic [4:0] pixels;
    logic [10:0] rx, ry;
    integer column, gx;
    always_comb begin
        rx = x - 11'd16; ry = y - 11'd16;
        column = int'(rx) / 12; gx = (int'(rx) % 12) / 2;
        case (ry[7:4])
            0: line_text = {"AP040 PC ",hex32(shown.pc),{23{8'h20}}};
            1: line_text = {"BUS ",hex32(shown.bus_addr)," STATE ",hex32(shown.state_bits),{13{8'h20}}};
            2: line_text = {"RST ",hex16(shown.resets)," ROM ",hex16(shown.rom_entries)," FAULT ",hex16(shown.faults),{12{8'h20}}};
            3: line_text = {"LAST ",hex8(shown.latest[95:88])," ",hex_digit(shown.latest[87:84])," ",hex32(shown.latest[79:48])," ",hex32(shown.latest[47:16])," ",hex16(shown.latest[15:0]),{8{8'h20}}};
            4: line_text = {"RAM1 ",hex8(shown.first_ram[95:88])," ",hex_digit(shown.first_ram[87:84])," ",hex32(shown.first_ram[79:48])," ",hex32(shown.first_ram[47:16])," ",hex16(shown.first_ram[15:0]),{8{8'h20}}};
            5: line_text = {"RST PC ",hex32(shown.reset_pc)," RAM ",hex_digit({3'd0,shown.ram_seen})," PTR ",hex_digit({3'd0,shown.pointer_frozen}),{13{8'h20}}};
            6: line_text = {"P0 ",hex32(shown.pointer0[63:32])," ",hex32(shown.pointer0[31:0])," ",hex_digit({3'd0,shown.pointer_valid[0]}),{18{8'h20}}};
            7: line_text = {"P1 ",hex32(shown.pointer1[63:32])," ",hex32(shown.pointer1[31:0])," ",hex_digit({3'd0,shown.pointer_valid[1]}),{18{8'h20}}};
            8: line_text = {"P2 ",hex32(shown.pointer2[63:32])," ",hex32(shown.pointer2[31:0])," ",hex_digit({3'd0,shown.pointer_valid[2]}),{18{8'h20}}};
            default: line_text = {40{8'h20}};
        endcase
        character = column < 40 ? line_text[319-8*column-:8] : 8'h20;
        pixels = glyph(character, ry[3:1]);
        box = enable_v[1] && !hblank && !vblank && x >= 16 && x < 496 && y >= 16 && y < 160;
        ink = box && gx < 5 && pixels[4-gx];
    end
endmodule
