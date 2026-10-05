# Resume: CRT 480i test path and 384p direction (2026-10-05)

Read `CLAUDE.md`, then this handoff. The previous release/scaler background is in
`RESUME-20261002-release-and-scaler.md`; this work is a separate CRT analog
experiment, not a continuation of the scaler-fault qualification.

## Current state

- Branch: `157CRT`; HEAD at handoff: `9ff0248` (`Add 480i interlacer test path`).
- The interlacer, PLL clock output, framework port wiring, analog test route,
  test bench, and no-HDMI configuration are committed at HEAD.
- `MacQuadra800.qsf` has an intentional uncommitted edit: keep the direct QSF
  `SYSTEMVERILOG_FILE rtl/mac_interlacer.sv` entry removed. The source is
  already included by `files.qip`; it must remain there and does not need a
  duplicate QSF entry. The `PARTITION_HIERARCHY` assignment has also moved to
  the end of the QSF; this is ordinary Quartus list reordering, not a
  functional change. The current source set is what the user intends to build.
- `.vscode/` was untracked earlier in the work; leave it alone if it remains.

## Hardware observation

The user reports a wobbly but stable CRT image from the 480i test build. Its
pink cast looks like MiSTer's startup image before normal coloration appears.
The user clarified that MiSTer's analog output has always started pink on
their CRT and switches to normal coloration after a moment. They do not know
whether SoG causes this or whether the board-level switch still matters;
historically SoG was controlled by a board switch and later by `MiSTer.ini`.
Do not change color or sync behavior based on the visual resemblance alone.
The user says 384p support is required; Game Boy is explicitly out of scope.

Treat the pink cast as a live analog-path / SoG configuration issue. Do not
dismiss it based on the HDMI/scaler implementation. The source-only inspection
found no sync-on-green insertion in the test RGB assignments. `sys/sys_top.v`
has a local `sog = cfg[9]`, but in this checkout that identifier is used for
SD/LED routing, not RGB sync. That does not rule out MiSTer configuration or
analog-board behavior outside those assignments. The exact effective SoG
setting remains unknown; confirm the setting and how it reaches the CRT path
before changing colors or sync polarity.

## Implemented test path

- `rtl/mac_interlacer.sv`: fixed 640x480 source to 480i output. Two alternating
  line buffers; 800 total output clocks per line; 70-clock HS; 240 active
  lines per field; alternating half-line field phase; field toggle crosses
  from C0 to C1 through two synchronizer stages.
- `rtl/pll_video.v`: C0 remains 25.175 MHz for this profile; C1 is 12.5875 MHz
  (divide by 56) for the interlaced output.
- `MacQuadra800.sv` and `sys/emu_ports.vh`: C1 carried to `sys_top`.
- `sys/sys_top.v`: under `MAC_480I_TEST`, raw core RGB/sync/DE feed the
  interlacer, and its RGB/sync feed the VGA DAC pins. Existing DAC disable and
  `av_dis` behavior is retained. Sync polarity options are applied.
- `MISTER_DEBUG_NOHDMI` is enabled for the CRT test build, compiling out ASCAL
  and the HDMI processing pipeline; HDMI video pins are tied low for
  `MAC_480I_TEST`.
- `MAC_480I_TEST` forces the core's 13-inch 640x480 mode and disables its C0
  runtime reconfiguration.
- `MAC_384P_TEST` now selects the native 12-inch DAFB timing, a static
  15.664444 MHz C0 PLL output, and direct progressive raw RGB/sync VGA pins.
  It disables runtime PLL reconfiguration and does not use the 480i half-rate
  clock. The profiles are separate compile-time choices. The QSF still
  selects `MAC_480I_TEST`; switch it to `MAC_384P_TEST` to build the 384p
  profile.

## Verification performed

- `make tb_mac_interlacer` passed under WSL Verilator 5.032. Checks include
  field period, alternating field phase, HS/VS pulse widths, 240 active rows,
  and selected source-line parity.
- Quartus 17.0.2 Analysis & Synthesis passed with 0 errors for the CRT-only
  no-HDMI configuration. The map report confirmed ASCAL absent, the two
  640x18 buffers inferred as M10K simple-dual-port RAM, C1 configured for
  12.5875 MHz, and HDMI pins held low. Reported: 61,537 logic cells, 17,778
  registers, 23 DSPs, 3 PLLs; 257 warnings, including expected stuck-low HDMI
  pins and ignored HDMI PLL assignments.
- This was Analysis & Synthesis only. No place-and-route/timing fit or RBF
  was made in this work. No MiSTer action was performed by the agent.
- The user's successful CRT image is a hardware observation, but its exact
  RBF/build identity and the effective SoG configuration state were not
  recorded here.
- The 384p profile wiring added in this continuation has not been synthesized
  or tested on hardware. Editor diagnostics report no errors and
  `git diff --check` passes; Quartus and Verilator are not available in this
  Windows environment.

## Required next direction: 384p

384p is a first-class requirement, not a later stretch goal. The DAFB already
has native 12-inch progressive timing in `rtl/dafb.sv`:

- Active: 512x384; horizontal total 640 (16 front, 48 sync, 64 back).
- Vertical total 407 (1 front, 3 sync, 19 back).
- C0: 15.664444 MHz; approximately 24.476 kHz horizontal and 60.14 Hz frame.

This is distinct from the 480i test raster. Keep the profiles explicit:

1. 480i test: fixed 13-inch input, C0=25.175 MHz, C1=12.5875 MHz, two fields.
2. 384p test: native 12-inch DAFB timing and matching C0=15.664444 MHz, direct
   progressive VGA output, selected with `MAC_384P_TEST`.

The regular core already has C0 runtime programming for the 12-inch mode, but
this test branch disables that reconfiguration. Clock selection constraints
are important: `rtl/pll_video.v` documents that the framework requires raw PLL
outputs for clock-select blocks and that muxing PLL taps is structurally
illegal. Prefer separate compile-time test profiles or a supported PLL
reconfiguration path; do not add an ordinary fabric clock mux between C0/C1.

For SoG/pink, first identify the effective SoG setting; the user is unsure
whether it is controlled by the board switch, `MiSTer.ini`, or both. Do not
alter color or sync behavior based on the startup resemblance. If a hardware
test becomes justified, use a static color-bar pattern or another known RGB
stimulus and change only a confirmed setting. The user has asked to avoid
reboot loops/repeat-load screens; inspect the MiSTer state first and ask before
any load. Do not deploy/reset while a guest is running, and do not use the
other MiSTer. The current MiSTer state has not been checked.

## Build and hardware rules

- Read `BUILD.md` before touching hardware or launching a build.
- No git worktrees. Do not modify RTL, QSF, QIP, or SDC during a Quartus flow.
- Only one Quartus flow globally; check process name and working directory
  before launching or waiting on one.
- The repo notes say to commit the build inputs before a fit. Do not commit
  without the user's request; resolve the intended build snapshot with the
  user if that becomes a blocker.
- No hardware load/reset while a guest is booting or running. Check the screen
  first. No repeated loads/reboots without explicit approval.

## Prompt for the next chat

Continue from `RESUME-20261005-analog-video-test.md`. Preserve the user's
uncommitted `MacQuadra800.qsf` changes. The separate `MAC_384P_TEST` profile is
wired but unbuilt; `MAC_480I_TEST` remains selected in the QSF. Synthesize and
verify each profile before any hardware load. The user reports that the
MiSTer's analog startup image is transiently pink before normal colors return;
they do not know whether SoG is responsible or whether the board switch still
applies. Do not change RGB/sync behavior without identifying the effective
setting. Check current MiSTer/guest state and ask before any load. Never run
repeated loads/reboots or disrupt a running guest without asking.
