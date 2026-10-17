`timescale 1ns/1ps
module tb_ap68040_diag_overlay;
    logic clk_sys=0, clk_vid=0;
    always #5 clk_sys=~clk_sys;
    always #7 clk_vid=~clk_vid;
    logic enable=0, machine_reset=0;
    logic [255:0] status=0;
    logic hblank=1, vblank=1;
    wire box, ink;
    ap68040_diag_overlay dut (
        .clk_sys(clk_sys), .clk_vid(clk_vid), .enable(enable),
        .machine_reset(machine_reset), .cpu_status(status),
        .ce_pixel(1'b1), .hblank(hblank), .vblank(vblank), .box(box), .ink(ink)
    );
    task automatic cpu_cycle;
        @(posedge clk_sys); @(negedge clk_sys);
    endtask
    task automatic fault(input logic [31:0] pc, addr, input logic [15:0] ssw);
        status[239]=1;
        status[223:128]={8'd2,4'd7,4'd2,pc,addr,ssw};
        cpu_cycle();
        status[239]=0;
    endtask
    task automatic snapshot;
        @(negedge clk_vid); vblank=0;
        repeat(4) @(negedge clk_vid);
        vblank=1;
        repeat(12) @(negedge clk_vid);
    endtask
    integer f;
    string output_file;
    initial begin
        status[255:240]=16'hA040;
        cpu_cycle(); enable=1; cpu_cycle();
        fault(32'h40800100,32'hf0000000,16'h0105);
        if(dut.captured.faults!=1 || dut.first_valid) $fatal(1,"early ROM fault capture");
        status[239]=1; status[223:128]={8'd11,4'd0,4'd0,32'h40800200,32'd0,16'd0};
        cpu_cycle(); status[239]=0;
        if(dut.captured.faults!=1) $fatal(1,"normal F-line traffic overwrote fault capture");
        status[238]=1; status[95:64]=32'h00123456; cpu_cycle(); status[238]=0;
        fault(32'h00123458,32'hdeadbeef,16'h0405);
        fault(32'h40801234,32'h87654321,16'h0106);
        if(dut.captured.first_ram[79:48]!=32'h00123458 || dut.captured.faults!=3)
            $fatal(1,"first post-RAM fault was overwritten");
        status[238]=1; status[95:64]=32'h4080008c; cpu_cycle(); status[238]=0; cpu_cycle();
        status[31:0]=32'h4080a870; status[127:96]=32'h50f06000; status[63:32]=32'h08010021;
        machine_reset=1; cpu_cycle(); cpu_cycle();
        machine_reset=0; cpu_cycle();
        if(dut.captured.resets!=1 || dut.captured.first_ram[79:48]!=32'h00123458)
            $fatal(1,"guest reset lost the capture");
        snapshot();
        if(dut.shown.latest[79:48]!=32'h40801234 || dut.shown.rom_entries!=1 ||
           dut.shown.bus_addr!=32'h50f06000 || dut.shown.resets!=1)
            $fatal(1,"video snapshot is not coherent");
        // Render the smallest supported width. This is synthetic test data,
        // not a screenshot of a hardware failure.
        if ($value$plusargs("image=%s",output_file)) begin
            f=$fopen(output_file,"wb");
            $fwrite(f,"P6\n512 128\n255\n");
            @(negedge clk_vid); vblank=0;
            for(integer row=0;row<128;row++) begin
                hblank=0;
                for(integer col=0;col<512;col++) begin
                    #1;
                    if(box) $fwrite(f,"%c%c%c",ink?8'hff:8'h10,ink?8'hff:8'h10,ink?8'hff:8'h10);
                    else $fwrite(f,"%c%c%c",8'h80,8'h80,8'h80);
                    @(negedge clk_vid);
                end
                hblank=1; repeat(4) @(negedge clk_vid);
            end
            $fclose(f);
        end
        // Check disabling while the raster is actually inside the box.
        vblank=1; hblank=1; repeat(4) @(negedge clk_vid); vblank=0;
        for(integer row=0;row<16;row++) begin
            hblank=0; repeat(512) @(negedge clk_vid);
            hblank=1; repeat(4) @(negedge clk_vid);
        end
        hblank=0; repeat(20) @(negedge clk_vid);
        if(!box) $fatal(1,"disabled-output test did not reach the overlay");
        enable=0; repeat(4) @(negedge clk_vid);
        if(box || ink) $fatal(1,"disabled overlay changes pixels");
        cpu_cycle(); enable=1; cpu_cycle(); snapshot();
        if(dut.shown.faults!=0 || dut.shown.first_ram!=0) $fatal(1,"rearming did not clear capture");
        status[255:240]=0;
        fault(32'h00111111,32'h22222222,16'h0405);
        if(dut.captured.faults!=0) $fatal(1,"legacy packet treated as native event");
        $display("PASS diagnostic capture, reset retention, coherent CDC, rearming and disabled overlay");
        $finish;
    end
endmodule
