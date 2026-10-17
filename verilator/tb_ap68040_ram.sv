`timescale 1ns/1ps
module check_ram #(parameter NB=4, OREG=0, AW=6)(output reg done=0);
reg clk=0; always #5 clk=~clk;
reg we=0,oce=1; reg [AW-1:0] wa=0,ra=0; reg [NB-1:0] be=0;
reg [NB*8-1:0] wd=0; wire [NB*8-1:0] q;
reg [NB*8-1:0] refmem[1<<AW];
reg [NB*8-1:0] prev,expected,rd;
ap68040_sdp_be #(.AW(AW),.NB(NB),.OREG(OREG)) dut(.clk(clk),.we(we),.waddr(wa),.wbe(be),.wdata(wd),.raddr(ra),.oce(oce),.q(q));
initial begin
for(integer i=0;i<(1<<AW);i=i+1) begin
 @(negedge clk); wa=i;ra=i;we=1;be='1;wd={NB{8'(i)}};
 @(posedge clk);refmem[i]=wd;
end
@(negedge clk);we=0;ra=0;
@(posedge clk);#1;prev=refmem[0];
for(integer j=0;j<400;j=j+1) begin
 @(negedge clk);
 wa=$urandom_range(0,(1<<AW)-1);ra=(j%3==0)?wa:$urandom_range(0,(1<<AW)-1);
 we=$urandom_range(0,1);be=$urandom;oce=$urandom_range(0,1);
 for(integer k=0;k<NB;k=k+1)wd[k*8+:8]=$urandom;
 @(posedge clk);
 rd=refmem[ra];
 if(!OREG)expected=rd;else if(oce)expected=prev;
 if(we)for(integer k=0;k<NB;k=k+1)if(be[k])refmem[wa][k*8+:8]=wd[k*8+:8];
 prev=rd;
 #1;
 if(j>2 && q!==expected)$fatal(1,"NB=%d OREG=%d step=%d got=%h expected=%h ra=%h wa=%h we=%b be=%h",NB,OREG,j,q,expected,ra,wa,we,be);
end
done=1;
end
endmodule
module tb_ap68040_ram;
wire [9:0] done;
check_ram #(.NB(1),.OREG(0)) a(done[0]);
check_ram #(.NB(1),.OREG(1)) b(done[1]);
check_ram #(.NB(2),.OREG(0)) c(done[2]);
check_ram #(.NB(2),.OREG(1)) d(done[3]);
check_ram #(.NB(4),.OREG(0)) e(done[4]);
check_ram #(.NB(4),.OREG(1)) f(done[5]);
check_ram #(.NB(16),.OREG(0)) g(done[6]);
check_ram #(.NB(16),.OREG(1)) h(done[7]);
check_ram #(.NB(16),.OREG(0),.AW(8)) i(done[8]);
check_ram #(.NB(16),.OREG(1),.AW(8)) j(done[9]);
initial begin wait(&done); $display("PASS AP68040 RAM byte enables and read latency");$finish;end
initial begin #20000;$fatal(1,"timeout");end
endmodule
