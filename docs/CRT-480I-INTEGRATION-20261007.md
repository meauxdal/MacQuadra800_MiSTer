# CRT 480i diagnostic profile: production integration, 2026-10-07

Added in the existing `157CRT` checkout; no commit or worktree. The selected
profile is now `MAC_TV525_DIAG=1` plus `MISTER_DEBUG_NOHDMI=1`.
`MAC_384P_TEST` is commented out. Select exactly one CRT test macro.

This profile outputs the free-running Stage 1 grid on a 640x480 logical
canvas, with the Stage 2 TV-coordinate OSD and component conversion. It
does not display the Mac framebuffer yet. The Mac remains in the core and
keeps its normal monitor selection, native clocks and video interrupts.
Guest reset is not connected to the new TV clock/reset path.

## Changes

- `rtl/pll_tv.v`: dedicated integer-N 50 MHz to nominal 27 MHz `altera_pll`,
  with no runtime reconfiguration. One mathematically exact solution is
  M=27/N=2/C=25 with a 675 MHz VCO. Quartus chooses the implementation;
  its actual counters/VCO and legality still need verification.
- `rtl/tv525_platform.sv`: asynchronous assertion on loss of TV PLL lock,
  three local edges to release reset in each domain, synchronized video
  disable and immediate analog drive inhibition. Both OSD mailbox endpoints
  reset on lock loss. This wrapper receives no guest reset.
- `sys/sys_top.v`: instantiates the TV PLL/platform only under the new
  macro. The TV clock feeds the analog board's DDIO clock output directly,
  without a fabric clock mux. HDMI video pins are inactive in this profile.
- The TV OSD uses the existing `io_osd_vga`, `io_strobe`, `io_din` interface
  and supplies `osd_status` to the core. The old analog OSD instance is
  bypassed only in this profile; native stream processing remains intact.
- All eight component DAC bits come from the TV pipeline. Primary VGA lanes
  carry the upper six bits; the existing SDIO repurposing carries the lower
  two bits in `{G,R,B}` lane order. The original SD/analog ownership selector
  is preserved, with startup/lock gating added when those pins serve the DAC.
- HS carries the authoritative delayed equalizing/serrated composite sync;
  VS stays inactive. `cs1` and `de1` use the delayed TV stream for the existing
  SD/LED board controls. HS/VS polarity overrides and the source-derived
  `csync` detector do not alter this diagnostic waveform.
- `MacQuadra800.qsf` and `files.qip` both list the new portable RTL,
  platform wrapper and PLL source.

Digital component codes are fixed for this profile, independent of Main's
normal RGB/YPbPr choice. This does **not** establish analog sync insertion:
the physical board still needs its correct SoG configuration/switch state.
No claim is made about the unidentified board's voltages. Pink/color
diagnosis remains deferred at the user's request.

## Constraints

`MacQuadra800.sdc` finds the derived TV PLL clock and constrains deliberate
crossings individually. It cuts only synchronizer heads and the PLL-lock
assertion path to startup-reset chains; local release-chain paths remain
timed. The held OSD payload has a 30 ns maximum data-path budget and no
cross-domain hold requirement. It is not hidden by a blanket asynchronous
clock-group exception. Missing TV clock/mailbox endpoints cause an explicit
constraint error so a future synthesis hierarchy change cannot silently
remove the intended constraints.

TV-register-to-DAC paths have a 10 ns propagation budget and no external
receiver hold requirement. `sys/sys_top.sdc` retains the usual broad VGA
exception for other profiles but omits it when the TV hierarchy exists.
This budget describes FPGA routing, not a calibrated analog cable delay.
TimeQuest endpoint matching, exception priority and constraint coverage
remain unverified until Quartus is run. Inspect ignored constraints and
unconstrained paths; do not infer success from simulation.

## Verification completed

- Strict Verilator `--Wall` lint passes for the platform and portable chain.
- `make tb_tv525_platform` passes 5,405,400 independently referenced samples:
  three startup/relock sequences, two complete field pairs per sequence,
  equalizing/serration waveform and aperture DE, analog disable and
  synchronized video disable. Loss of lock inhibits drive immediately,
  including without a TV edge. No PLL primitive is modeled by this test.
- Preprocessing compares normal/historical `sys_top` RTL with HEAD after
  stripping comments/whitespace. Normal, no-HDMI, no-VGA-OSD, old 384p,
  old 480i and dual-SDRAM configurations match. The new configuration selects
  the TV PLL/platform, complete DAC bits and authoritative sync, with no old
  analog OSD/interlacer instance. This is a branch-preservation check, not
  whole-core synthesis or hardware qualification.
- Stage 1 and Stage 2 digital results remain described in their reports;
  their portable RTL was not changed by this integration.
- `git diff --check` passes. No Mac, CPU, DDR, native PLL or old interlacer
  source was edited.

Reproduce the new test from `verilator/` in WSL:

```sh
make tb_tv525_platform
```

Logs: `scratch/tv525_platform_build.log`; preprocessing script/baseline are
under `scratch/tv525_route_review/`.

## Build state and next action

The user clarified **do not run Quartus**. No Analysis & Synthesis or fit
result is available for these inputs. A background check launch was attempted
before that clarification but produced no logs/result; a retry was refused
because a Quartus process was already running. A targeted check confirmed
this chat's attempted supervisor PID 27696 is no longer running. No unrelated
Quartus process was stopped. No hardware operation was performed.

A build-only `scripts/local.env` was created for the detected local Windows
Quartus 17.0.2 Lite installation. It has no MiSTer address or credentials.
Build stamp generation alone ran and set `build_id.v` to `261007`; this is
not a synthesis/fit. The user may change the stamp before their compile.

Previous `db/`, `incremental_db/` and `output_files/` were preserved under
`scratch/tv525_integration_20261007_001/previous-build/`. This includes a0/a1/a2
RBFs and old reports. They were moved rather than deleted. Their old input
identity is still unknown. The `_001` archive records the first prepared
inputs before the final constraint-review adjustment; `_002` contains the
final source archive and SHA-256 manifest. No old report proves this profile.

When the user chooses to compile, first check **all** Quartus processes on
the selected host and keep the normal global wait gate. Freeze these inputs
and run `bash scripts/build_only.sh --check` using Git Bash on Windows.
Check OSD bitmap block-RAM inference (32,768 bits), actual PLL frequency and
VCO, multiple-driver/clock warnings and SD/VGA pin routing. Then run a full
fit and inspect per-domain setup/hold, CDC/constraints, pin propagation and
ALM/RAM/DSP/PLL use. Do not assume the October 5 fit is a current baseline.

No hardware load is authorized by this document. Before any diagnostic load,
identify the board/SoG contract and inspect a fresh safe-shutdown/menu screen
on the designated MiSTer. The current guest state remains unknown.
