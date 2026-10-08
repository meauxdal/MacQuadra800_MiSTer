"""Preprocess both CRT configurations and preserve all unrelated sys_top branches."""
from pathlib import Path
import re
import subprocess

root = Path(__file__).resolve().parents[1]
baseline = root / "scratch/tv_frame_routes_baseline.v"
baseline.write_bytes(subprocess.check_output(["git", "show", "a42ea84864c9f509ce7bd2fde9864659ae3ac9f7:sys/sys_top.v"], cwd=root))

def preprocess(path, defines):
    value = subprocess.check_output(["verilator", "-E", "-P", "+incdir+"+str(root/"sys"),
                                     *("+define+"+d for d in defines), str(path)], text=True, cwd=root)
    value = re.sub(r"/\*.*?\*/|//[^\n]*", "", value, flags=re.S)
    return re.sub(r"\s+", "", value)

for defines in [[], ["MISTER_DEBUG_NOHDMI"], ["MISTER_DISABLE_VGA_OSD"],
                ["MAC_384P_TEST", "MISTER_DEBUG_NOHDMI"],
                ["MAC_480I_TEST", "MISTER_DEBUG_NOHDMI"], ["MISTER_DUAL_SDRAM"]]:
    assert preprocess(baseline, defines) == preprocess(root/"sys/sys_top.v", defines), defines
    print("PASS unchanged sys_top branch:", defines or "normal")

for defines in [["MAC_TV525_DIAG", "MISTER_DEBUG_NOHDMI"], ["MAC_TV525_DIAG"]]:
    value = preprocess(root/"sys/sys_top.v", defines)
    for required in ["tv525_platform#(.BUFFERED(1))crt_tv(", "tv_ddr_arbitertv_vbuf_arbiter(",
                     "assignvga_tx_clk=clk_tv525;", "wirecs1=tv525_drive?tv525_cs_n:1'b1;",
                     "wire[1:0]vga_r=tv525_low_r;", "assignVGA_HS=tv525_drive?tv525_hs_n:1'bZ;",
                     ".TV_NATIVE_RGB(tv_native_rgb)", ".source_ce(ce_pix)",
                     ".b_address(tv_store_address)", ".address(vbuf_address)"]:
        assert required in value, required
    assert "osdvga_osd(" not in value and "mac_interlacerinterlacer(" not in value
    if "MISTER_DEBUG_NOHDMI" in defines:
        assert "assignscaler_read=0;" in value and "ascal#(" not in value
    else:
        assert "ascal#(" in value and ".avl_address(scaler_address)" in value
        assert ".avl_address(vbuf_address)" not in value
    print("PASS buffered TV routes and exclusive/arbitrated vbuf ownership:", defines)

emu = preprocess(root/"MacQuadra800.sv", ["MAC_TV525_DIAG"])
for required in ["assignTV_NATIVE_RGB={mac_vga_r,mac_vga_g,mac_vga_b};", "assignTV_NATIVE_DE=mac_de;",
                 "assignTV_NATIVE_RESET=!nreset_vid;", ".native_frame_start(native_frame_start)"]:
    assert required in emu, required
print("PASS emu exports raw DAFB tap before video_freak and MT32/normal VGA overlays")
