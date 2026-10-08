#include "Vtv_dafb_pipeline.h"
#include "verilated.h"
#include <array>
#include <vector>
#include <algorithm>
#include <stdexcept>
#include <iostream>
#include <cstdint>

static void run(bool twelve) {
    Vtv_dafb_pipeline d;
    std::vector<std::array<uint32_t,4>> ram(262144);
    uint64_t t=0,ns=79,nm=43,nt=111,source_ticks=0,source_pixels=0,tv_pixels=0;
    unsigned remaining=0,index=0,delay=0,base=0,wremaining=0,windex=0,wbase=0;
    int pairs=0;bool acquired=false,seen_picture=false;
    int w=twelve?512:640,h=twelve?384:480,totalx=twelve?640:800,totaly=twelve?407:525;
    d.mon_12in=twelve;d.reset_tv=1;d.reset_source=1;d.reset_registers=1;
    d.eval();
    auto fail=[&](const char* why){throw std::runtime_error(std::string(why)+" ps="+std::to_string(t));};
    while(pairs<6) {
        t=std::min({ns,nm,nt});
        bool s=t==ns,m=t==nm,v=t==nt;
        bool sr=s&&!d.clk_source,mr=m&&!d.clk_mem,vr=v&&!d.clk_tv;
        d.reset_registers=t<500000;d.reset_source=t<2000000;d.reset_tv=t<1000000;
        // Palette zero = white via real DAFB host register protocol, before
        // releasing the native scanout. sel pulses separated by idle edges.
        d.reg_sel=0;d.reg_wdata=255;d.reg_addr=0x84;
        if(t>=600000 && t<610000){d.reg_sel=1;d.reg_addr=0x80;d.reg_wdata=0;}
        if((t>=640000&&t<650000)||(t>=680000&&t<690000)||(t>=720000&&t<730000))d.reg_sel=1;
        if(mr) {
            d.waitrequest=((t/10000)%19)==0;d.readdatavalid=0;
            if(remaining) {
                if(delay)--delay;
                else {d.readdatavalid=1;for(int k=0;k<4;k++)d.readdata[k]=ram.at(base+index)[k];}
            }
        }
        d.eval();uint32_t tag=d.tag_raw;
        if(mr) {
            if(d.read&&!d.waitrequest) {
                if(remaining||wremaining)fail("native overlapping memory commands");
                base=d.address-0x2180000;remaining=d.burstcount;index=0;delay=27;
            }
            if(d.write&&!d.waitrequest) {
                if(!wremaining){wbase=d.address-0x2180000;wremaining=d.burstcount;windex=0;}
                for(int k=0;k<4;k++) {
                    if(d.writedata[k]!=0x00ffffff)fail("native capture RGB or packing mismatch");
                    ram.at(wbase+windex)[k]=d.writedata[k];
                }
                --wremaining;++windex;
            }
            if(d.readdatavalid){--remaining;++index;}
        }
        if(s){d.clk_source=!d.clk_source;ns+=twelve?31921:19861;}
        if(m){d.clk_mem=!d.clk_mem;nm+=5000;}
        if(v){d.clk_tv=!d.clk_tv;nt+=18518;}
        d.eval();
        if(sr&&!d.reset_source) {
            if(d.native_frame) {
                if(acquired && source_ticks!=uint64_t(totalx*totaly))fail("native frame period changed");
                acquired=true;source_ticks=0;
            }
            if(acquired) {
                auto phase=source_ticks%(totalx*totaly);unsigned x=phase%totalx,y=phase/totalx;
                bool active=x<unsigned(w)&&y<unsigned(h);
                if(bool(d.native_de)!=active || bool(d.native_line)!=(x==0&&y<unsigned(h)) ||
                   bool(d.native_frame)!=(phase==0) || !d.native_ce || d.native_width!=w || d.native_height!=h)
                    fail("native marker, CE, metadata or DE latency mismatch");
                if(active) {if(d.native_rgb!=0xffffff)fail("native CLUT latency mismatch");++source_pixels;}
                ++source_ticks;
            }
        }
        if(vr&&!d.reset_tv) {
            if(tag&(1u<<22))++pairs;
            if(tag&(1u<<25)) {
                int x=(tag>>9)&1023,y=tag&511;
                bool inside=x>=(640-w)/2&&x<(640+w)/2&&y>=(480-h)/2&&y<(480+h)/2;
                if(d.rgb_raw)seen_picture=true;
                if(seen_picture && d.rgb_raw!=(inside?0xffffffu:0u))fail("native canvas pixel or border mismatch");
                if(seen_picture && (tag&(1u<<24)))++tv_pixels;
            }
        }
    }
    if(d.overflows||d.underruns||d.published<4||tv_pixels<1000000)fail("native coverage or buffer faults");
    std::cout<<"PASS DAFB "<<w<<"x"<<h<<" source_pixels="<<source_pixels<<" canvas_pixels="<<tv_pixels
             <<" published="<<d.published<<" overflow="<<d.overflows<<" underrun="<<d.underruns<<std::endl;
}
int main(int argc,char**argv) {
    Verilated::commandArgs(argc,argv);
    try{run(true);run(false);}catch(const std::exception&e){std::cerr<<"FAIL "<<e.what()<<std::endl;return 1;}
}
