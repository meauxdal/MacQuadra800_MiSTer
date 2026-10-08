# Native Mac framebuffer to independent TV canvas

Implemented in the existing `157CRT` checkout, based on `a42ea84`, without
commits, Quartus, hardware access, guest reset, or deployment.
The user has qualified the preceding diagnostic pipeline on an early-2000s
Sony Trinitron through the passive MiSTer Addons component cable: stable,
near-flawless picture and correct color. That observation supersedes older
hardware-status notes. This new buffered Mac image still needs the user's
compile and hardware check.

## Selected profile and preserved output

`MAC_TV525_DIAG` now instantiates `tv525_platform` with `BUFFERED=1`.
`MISTER_DEBUG_NOHDMI` remains selected for the current CRT-only compile.
**The TV allocation does not depend on omitting ASCAL.** Both the CRT-only
and TV-plus-ASCAL routes have been checked; restoring HDMI requires a new
combined fit/resource/timing qualification, not relocating the TV frames.

The timing generator, sample-to-column mapping, OSD, conversion, PLL and
physical DAC/pin routes are unchanged. The first temporal field still draws
odd canvas rows; `frame_start` selects a descriptor for both fields.
The synchronous canvas RAM adds one sample of delay to RGB and every tag;
OSD plus conversion retain their five stages, so the buffered route has six
register stages altogether. Sync never derives from the Mac stream.

`BUFFERED=0` retains the previous diagnostic implementation and latency.
The grid remains the startup fallback until a complete frame exists. After
that, source loss repeats the last completed image. Memory starvation emits
black for an entire missed line; borders and black fallback remain inside
picture DE. OSD remains downstream and usable in every case.

## Native tap and geometry

DAFB now exports first-active-pixel line/frame markers and its internally
synchronized monitor geometry. Markers register on the same edge as the
CLUT RGB read and `hb_r/vb_r/act_q`. `quadra800` passes them through;
`emu` exports `{mac_vga_r,mac_vga_g,mac_vga_b}`, `mac_de`, native markers,
width/height and `!nreset_vid` through conditional `TV_NATIVE_*` ports.
The tap is before `video_freak`, MT32 LCD composition, scanlines and normal
VGA OSD. TV OSD is composed independently after canvas scanout.

Capture honors `CE_PIXEL`, including gaps. DAFB currently asserts CE every
native dot-clock cycle. No DAFB counters, monitor selection, PLL retargeting,
VBL interrupt or audio behavior is retimed by the TV path.

| Native size | Canvas origin | Native bytes per row |
| --- | --- | --- |
| 512x342 synthetic portable source | (64,69) | 2048 |
| 512x384 Quadra | (64,48) | 2048 |
| 640x480 Quadra | (0,0) | 2560 |

Native rows are densely packed RGBx8888, with zero in the padding byte;
all 24 RGB bits are retained. The odd 342 origin is preserved exactly:
first temporal field begins with source row zero at canvas row 69.
There is no interpolation or source timing change.

## Memory reservation and arbitration

ASCAL's actual `buf_offset` maps its three slots to base, base+size,
base+2*size. With current 8 MiB slots it uses `[0x20000000,0x21800000)`;
small-VBUF mode uses less. Upstream Main places its framebuffer at
`0x22000000`, after the 32 MiB core-video reservation
([Main video.cpp](https://raw.githubusercontent.com/MiSTer-devel/Main_MiSTer/master/video.cpp)).

TV exclusively reserves `[0x21800000,0x21C00000)` within that core region:

| Slot | Byte base | Maximum exclusive end |
| --- | --- | --- |
| 0 | 0x21800000 | 0x2192C000 |
| 1 | 0x2192C000 | 0x21A58000 |
| 2 | 0x21A58000 | 0x21B84000 |

This leaves 0x7C000 unused bytes in the 4 MiB reservation. The store does
not access ROM at 0x38000000, legacy RAM at 0x30000000, Ethernet near
0x1FF00000, Main's framebuffer, or ASCAL's slots. Future changes to ASCAL
RAMSIZE/RAMBASE or custom framebuffer allocations must honor this map.

The existing `vbuf` port uses 16-byte word addresses at `clk_100m`, all 16
byte enables, and accepted beats defined by request && !waitrequest.
`tv_ddr_arbiter` gives ASCAL and TV separate master signals. It alternates
grants when both request and retains the grant through every accepted write
beat or every read response. Only one read burst is outstanding, so replies
cannot change destinations in flight. Capture stages complete 16-beat bursts
before asserting write. TV prefetch reads 128 or 160 beats per native line.

The existing `sysmem_lite` startup gate and safe terminator remain in place.
Reset inhibits new arbiter grants, preserves presented commands, and drains
the accepted burst. If reset cancels ASCAL, its outstanding write tail drains
with zero byte enables and its read tail is discarded. A restarting ASCAL
waits until that old grant has drained. TV finishes its staged burst and
invalidates the capture. Guest reset does not reset TV timing, FIFO pointers,
memory ownership or the line/pair mailboxes.

## Ownership, CDC and deadlines

`tv_frame_store` is the sole memory-domain owner: one WRITING slot, at most
one latest READY slot, and one DISPLAYING slot; all others are FREE.
START abandons an incomplete capture. END publishes only when geometry,
pixel count, overflow status and all accepted writes are valid. A newer
READY replaces the older non-displayed READY. Pair requests select the
latest completed READY; absent READY, DISPLAYING repeats. Writer allocation
excludes READY and DISPLAYING. A frame cannot change between the two fields.

`tv_video_capture` validates line lengths and coherent frame geometry, packs
four pixels per word, and adds START/END/bad records. Overflow invalidates
the whole frame; missing END cannot publish. Source reset invalidates capture
without resetting one FIFO endpoint. FIFO pointers initialize only at FPGA
configuration and use two-stage Gray synchronizers with registered dual-clock
RAM reads. No metadata tuple crosses as independent synchronized bits.

TV sends held pair and line requests; memory acknowledges pair selection
and complete-line filling. A line request holds bank and canvas row through
acknowledgement. Scanout tracks completed row metadata separately for each
bank. It requests one electrical line ahead, decides readiness immediately
before the picture aperture, and holds that decision throughout the line.
Late data cannot turn a partly black line into a partly valid line. Pair
selection missing the initial blanking deadline blacks the entire pair.
Memory responses continue draining after deadlines; TV never waits on DDR.

The capture FIFO has 1024 134-bit records (approximately 4096 source pixels);
two line banks use 512x128 bits, and staging uses 16x128 bits. These arrays
request M10K inference. Their actual packing, ALM cost and service margin
require Quartus. The memory model establishes behavior for its exercised
service bounds, not a measured worst-case HPS bandwidth guarantee.

SDC adds explicit Gray delay/skew and held-line-mailbox budgets. In the
buffered configuration, the former blanket native-clock group exception is
replaced with exceptions that leave the Gray buses constrainable. Normal
profiles retain the former group. TimeQuest endpoint matching, priority,
constraint coverage and routing budgets remain user-run compile checks.

Counters are internal RTL outputs, available for simulation/SignalTap:
published valid captures, discarded/incomplete/obsolete frames, pair repeats,
lost capture records, and missed picture-line deadlines. No HPS register
transport or new OSD controls are introduced.

## Independent verification

Reproduce from `verilator/` in WSL with the existing Verilator 5.032 tools:

```sh
make tb_tv_frame tb_tv_dafb tb_tv_frame_owner tb_tv_ddr_arbiter
make tb_sysmem_vbuf_gate
python3 check_tv_frame_routes.py
make tb_tv525_platform tb_tv525_output
```

The portable bench checks every electrical sample against an independent
525-line sync/DE/CE/parity/coordinate reference, including source loss/reset,
and compares every displayed RGB pixel against coordinate/frame-ID formulas.
It compares all downstream component values and tags at their exact latency.
Both fields, first/last rows/columns, all borders, the odd 342 origin, RGB
bits, different clock phases, native approximately 60.14 Hz 384 mode, CE gaps,
geometry change, competing scaler reads, randomized waits/read delays, dropped
input, source loss, FIFO overflow and missed-line fallback are exercised.

Results:

| Test | Result |
| --- | --- |
| Portable healthy geometries | 7 full pairs each; 7,207,201 samples and 2,457,600 logical pixels per run; zero overflow/underrun |
| Mode change 640x480 to 512x384 | 8 full pairs, 8,108,101 sample checks; zero overflow/underrun |
| CE gaps and different clock phases | 7 full pairs; zero overflow/underrun |
| DDR outage/dropped input/source loss/reset | 8 full pairs; 4,048 lost records, 15 missed lines, invalid frames rejected; no tears, ownership faults or TV phase changes |
| Actual DAFB 512x384 tap | 1,972,749 source pixels and 1,213,376 canvas pixels; 10 published frames; zero overflow/underrun |
| Actual DAFB 640x480 tap | 3,072,000 source pixels and 1,228,800 canvas pixels; 10 published frames; zero overflow/underrun |
| Owner policy | Latest READY selected, exact repeat/drop counts, incomplete/invalid/reset captures rejected, DISPLAYING never written |
| DDR arbiter | 4,177 completed transactions, 2,124 read bursts, 2,142 write bursts, 200 resets, 344 masked drain beats |
| Existing DDR startup gate | PASS, 32 reset/startup cases |
| Route preprocessing | Normal and historical routes unchanged; raw native tap and shared-port arbitration present in TV with/without ASCAL |
| Existing platform/output regressions | 5,405,400 independent platform samples; all 16,777,216 RGB values; 58,560,751 wrapper tag/pin checks and 9,008,996 OSD pixel checks |

The portable new RTL passes `--Wall` lint; only deliberately unused fixture
ports are suppressed. DAFB uses the legacy bench warning policy. Native tests
use a zero-filled registered VRAM fixture and program CLUT entry zero through
the actual register interface. They validate the real tap, not a guest boot.
Approximately every other native frame is intentionally dropped at the
29.97 complete-pair cadence; source loss repeats an unchanged descriptor.

Logs are under `scratch/tv_frame_final.log`, `tv_dafb_build.log`,
`tv_owner_build.log`, `tv_arbiter_build.log`, `tv_frame_routes.log`, and
`tv_frame_legacy.log`; buffered platform lint and startup gate results are in
`tv_buffered_platform_lint.log` and `tv_frame_sysmem.log`.
These were the pre-compile results. The subsequent user-run synthesis and
failed fitter are documented below; measured memory-service envelope,
guest boot/audio regression and new framebuffer CRT qualification remain open.

For the user's compile: retain the global Quartus-process check and frozen
inputs policy. Inspect M10K inference, actual PLL frequency, constraints and
CDC endpoints, all domain setup/hold, DAC routes, and resource use. The current
profile remains CRT-only; qualify a combined ASCAL build separately when it
is restored. Hardware load/reset still requires user authorization and a fresh
guest-state check on the designated MiSTer only.

## User-run fitter failure and SDC repair

The user-run Quartus 17.0.2 reports in `output_files/` show Analysis &
Synthesis successful at 03:17:22 on October 7, followed by a fitter failure
at 03:17:59. The first fatal error is `Error (332000): Unknown option:
-clock` while evaluating `all_registers -clock $native_video_clocks` in
`MacQuadra800.sdc`. `Read_sdc failed` follows; generic Error 11802 appears
at the end of fitter preparation. This report does not establish a resource
overflow or successful placement. Its preparation estimate is 31,247/41,910
ALMs (75%), 430/553 M10Ks (78%), and four/six PLLs.

The RAM Summary confirms M10K inference for the capture FIFO (1024x110
after constant padding-bit removal), line RAM (512x96), and TV OSD bitmap
(4096x8). The small write staging array is implemented in logic; no staging
RAM appears in the RAM Summary. No array-size or RTL change was needed for
the reported fatal error.

The repair replaces the unsupported `all_registers -clock` with Quartus 17
collection APIs: `get_clock_info -targets`, `get_fanouts -no_logic`, and
`add_to_collection`. It collects the buffered/inverted native clock fanout,
then excludes the write Gray launch registers and read Gray synchronizer
heads from the corresponding native-domain false paths. Both endpoints must
be found in that fanout or constraint loading raises an explicit error.
The normal-profile clock-group branch and the 8 ns Gray delay/skew budgets
remain. The installed Quartus 17 Standard help documents these APIs; no
Quartus executable was invoked to verify this repair.

Fresh verification:

- Tcl 8.6 executes the full SDC with strict Quartus 17 API mocks for normal,
  diagnostic and buffered profiles; Gray setup paths remain outside false
  paths, and missing native fanout endpoints fail closed. This checks Tcl
  evaluation and exception topology, not a synthesized TimeQuest netlist.
  Harness: `scratch/check_tv_sdc_repair.py`; run with the bundled Windows
  Python, which includes tkinter.
- `make tb_tv_frame tb_tv_dafb tb_tv_frame_owner tb_tv_ddr_arbiter
  tb_sysmem_vbuf_gate` passes again, including all geometries, fault cases,
  real DAFB taps, owner policy, arbiter burst draining and 32 startup cases.
- `python3 check_tv_frame_routes.py` passes both TV routes (with and without
  ASCAL) and unchanged historical branches. `git diff --check` passes.

Simulation logs: `scratch/tv_fit_repair_sim.log` and
`scratch/tv_fit_repair_routes.log`. Failed reports, repaired SDC and Tcl
check output are preserved in `scratch/tv_fit_repair_20261007/` so a later
compile cannot erase the diagnosis. The prior `.sof`, `.rbf` and `.sta.*`
files in `output_files/` are from the earlier 02:25 diagnostic build and
must not be treated as artifacts or timing results for the failed 03:17 build.

The next user-run compile must verify actual fanout/Gray/mailbox endpoint
matching, ignored exceptions, Gray delay/skew, routing and all-domain timing.
A successful fit is still unverified, as is a combined ASCAL fit. No new
Quartus flow, hardware load, reset, guest input, commit or worktree was made
for this repair. TV timing, OSD, component arithmetic, physical routes and
native DAFB behavior are unchanged.
