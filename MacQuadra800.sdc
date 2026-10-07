derive_pll_clocks
derive_clock_uncertainty

# core specific constraints

# ----------------------------------------------------------------------------
# Pixel-clock domain (pll_video) — declare it asynchronous to everything else.
# ----------------------------------------------------------------------------
# The DAFB scanout runs on clk_vid (rtl/pll_video.v, 25.175 MHz for the 13"
# monitor; the 12" 512x384 option retargets the same output to 15.664 MHz at
# runtime through sys/pll_cfg, which is SLOWER than the static 25.175 MHz
# constraint derived here, so STA covers both rates). sys_top.sdc
# decouples every clock domain with set_clock_groups, but its core-PLL pattern
# matches only the MAIN pll, so a second PLL lands in NO group and every
# framework path touching CLK_VIDEO (ascal video-in, OSD, HDMI transfer) gets
# timed against unrelated domains — design-wide false violations. MacLC hit
# exactly this (MacLC.sdc:78) and the fix is the same as pll_hdmi/pll_audio.
#
# The deliberate clk_sys <-> clk_vid crossings this blesses are safe by
# construction: (a) dual-clock M10Ks (the VRAM read port in MacQuadra800.sv — no
# timed cross-port arc), (b) 2FF *_meta synchronizers (fb_base/stride/mode into
# the scanout, the video-domain reset, and the VBL toggle back into clk_sys),
# and (c) vid_stride into the VRAM address mapper, which BOTH ports have to
# agree on, so it stays a clk_sys signal read combinationally by the clk_vid
# port -- quasi-static, and a change means the guest is redrawing anyway.
set_clock_groups -asynchronous -group [get_clocks {emu|pllv|*|divclk}]

# Belt and braces: the synchronizer heads (redundant with the group above).
set_false_path -to [get_keepers {*fb_base_meta* *stride_meta* *mode_meta*}]
set_false_path -to [get_keepers {*vidrst_meta* *vbl_meta* *mon_meta*}]

# C1 is the half-rate output of the video PLL; the field toggle crosses from
# C0 to C1 through this first synchronizer stage.
set_false_path -to [get_keepers {*interlacer|field_sync_meta*}]

# Independent TV domain: constrain actual crossings individually. A blanket
# asynchronous clock-group cut would also hide the held configuration bus.
set tv525_clocks [get_clocks -nowarn {*tv525_pll|*|divclk}]
if {[get_collection_size [get_registers -nowarn {*crt_tv|*}]] != 0} {
    if {[get_collection_size $tv525_clocks] == 0} {
        error "TV diagnostic exists but its derived 27 MHz PLL clock was not found"
    }
    set_false_path -to [get_registers {*crt_tv|*|req_meta *crt_tv|*|ack_meta *crt_tv|disable_meta}]
    # PLL-lock assertion is asynchronous; release is a 3FF chain per domain.
    set_false_path -from [get_pins {*tv525_pll|*|locked}] -to [get_registers {*crt_tv|tv_reset_pipe* *crt_tv|sys_reset_pipe*}]
    # Receiver has two synchronizer stages plus a frame-boundary wait before
    # sampling the held bus. Bound physical data delay to one 27 MHz period.
    set tv525_payload [get_registers {*crt_tv|*|config_payload*}]
    set tv525_config [get_registers {*crt_tv|*|tv_config*}]
    if {[get_collection_size $tv525_payload] == 0 || [get_collection_size $tv525_config] == 0} {
        error "TV OSD mailbox endpoints were not found; review synthesis hierarchy"
    }
    set_max_delay 30.0 -from $tv525_payload -to $tv525_config
    set_false_path -hold -from $tv525_payload -to $tv525_config
    # Analog DAC has no receiver clock; budget 10 ns for register-to-pin
    # propagation. This is an FPGA routing budget, not an analog voltage spec.
    set tv525_dac_ports [get_ports {VGA_R* VGA_G* VGA_B* VGA_HS VGA_VS SDIO_CLK SDIO_CMD SDIO_DAT*}]
    set_max_delay 10.0 -from $tv525_clocks -to $tv525_dac_ports
    set_false_path -hold -from $tv525_clocks -to $tv525_dac_ports
}
