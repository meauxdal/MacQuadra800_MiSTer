# Portable Mac-to-480i output: engineering plan

Planning baseline: 2026-10-06, branch `157CRT`, HEAD
`bb8db1eb4c7fb752f53cdf07e6f1eb66318e31d4`. The checkout was clean when
inspected. This document is the only intended change in this planning task.
No RTL implementation, simulation run, Quartus flow, commit, deployment,
guest input, reset, or reboot is authorized by this plan alone.

Implementation update: the user authorized starting the plan on 2026-10-06.
The standalone Stage 1 raster/pattern gate now passes; see
[Stage 1 results and reproduction commands](CRT-480I-STAGE1-20261006.md).
The standalone Stage 2 component/TV-coordinate OSD simulation also passes;
see [Stage 2 results](CRT-480I-STAGE2-20261006.md). Production pin/clock
integration, FPGA fitting, Mac capture, and hardware qualification remain.

2026-10-07 update: the separate diagnostic profile, TV PLL/platform reset,
TV OSD host connection, DAC routing and initial constraints are now added;
see [production integration notes](CRT-480I-INTEGRATION-20261007.md).
Quartus verification remains pending; the user asked not to run it.

## Recommendation

Build a free-running 525-line, two-field television raster first and prove
its timing with diagnostic pictures. Then feed it completed Mac frames from
external memory, using small on-chip FIFOs and line buffers. Keep the normal
Mac raster and video branch; tap active RGB before the normal output
processing. Place source pixels one-for-one in a logical 640x480 canvas.
Apply analog color conversion and sync routing **after** TV raster creation.

The hardware path confirmed in this chat is a passive MiSTer Addons
VGA-to-component cable. Consequently the first physical output target is
525-line/59.94-field YPbPr, with bi-level composite sync on Y through the
analog board. The cable does not convert RGB into YPbPr. An NTSC chroma
encoder, burst, and subcarrier are unnecessary for this component path.
Keep an encoder interface for later composite/S-video use, but do not make
that a prerequisite for proving this CRT path.

Start with an explicit experimental CRT profile in this checkout. Preserve
normal-core behavior and source timings. Prefer eventual simultaneous normal
HDMI and TV analog output if fitting permits it. If the added memory clients,
OSD, and timing logic exceed practical area/timing limits, a separate CRT-only
profile is acceptable under the current request. Do not silently remove Mac
features or change CPU timing to make the normal core fit.

## What the actual sources establish

| Evidence | Finding and implication |
| --- | --- |
| `MacQuadra800.qsf:636,638` | Both `MAC_384P_TEST=1` and `MISTER_DEBUG_NOHDMI=1` are active. The nearby comment claiming ASCAL is enabled is stale. `MAC_480I_TEST` is not active. |
| `files.qip:5` | Includes `rtl/mac_interlacer.sv`; the direct QSF source entry is absent. Do not restore a redundant entry merely to match older notes. |
| `rtl/dafb.sv:299` and `rtl/pll_video.v` | 512x384 uses 640x407 totals and C0=15.664444 MHz: approximately 24.476 kHz H and 60.138 frames/s. This is a native progressive source mode, not 384 lines embedded in 480i. The other source mode is 640x480, 800x525 at 25.175 MHz, approximately 59.940476 frames/s. |
| `MacQuadra800.sv:287` | The test macros force the monitor mode and disable source PLL reconfiguration. Normal mode has a separate monitor-selection/reconfiguration path. Restore that normal path for asynchronous conversion; TV mode should not dictate the guest monitor sense. |
| `rtl/mac_interlacer.sv:108` | The output waits for synchronized source-frame toggles and resets output counters on every toggle. It does not generate an independent 525-line frame. Its ordinary HS width is 70/12.5875 MHz = about 5.56 us; VS is a rectangular pulse, with no specified equalizing/serration sequence. |
| `rtl/mac_interlacer.sv` | Two 640x24 arrays alternate without a completed-line ownership handshake. The proof-of-concept depends on a fixed relationship between input/output rates and phase. Source RGB is 24 bits, despite the handoff's historical 18-bit RAM description. |
| `verilator/tb_mac_interlacer.sv` | The synthetic clocks are 50/25 MHz; checks run for two completed fields and examine the first pixel of each row. They verify selected PoC behavior, not absolute NTSC timing, full-row integrity, long-term drift, or asynchronous operation. |
| `sys/sys_top.v:1574` | Both test DAC routes bypass `vga_out`, `yc_out`, composite-sync selection, and external-subcarrier selection. `vga_out` normally packs component channels as `{Pr,Y,Pb}`. Raw RGB on a passive component path is a credible explanation for bad color, but the original failing bitstream/path/settings have not been identified well enough to prove causation. |
| `sys/sys_top.v:1488` | Existing `yc_out` runs on the source `clk_vid`, with the original progressive stream. It is not encoding the interlacer output. |
| `sys/sys_top.v:2016` | Existing `csync` derives sync from HS/VS and measured pulse lengths. It is not an independently specified half-line NTSC pulse sequencer; do not rely on it to synthesize the new vertical waveform. |
| `sys/sys_top.v:304` | Component selection is `cfg[5]`. Local `sog=cfg[9]` appears in SD/LED routing; no negative sync level is inserted into green RGB by the test assignments. Board revision, switch wiring, and effective configuration must be checked. |
| Latest local `output_files` reports | October 5 fit: 34,532/41,910 ALMs, 417/553 RAM blocks, 23/112 DSP blocks, 3/6 PLLs; CPU setup slack -0.916 ns. Build stamp on disk is `261005`; several a0/a1/a2 RBFs exist. These reports predate current HEAD and lack a verified input-hash manifest linking them to today's files or the observed TV picture. They are budget evidence, not current validation. |

Read `CLAUDE.md`, `BUILD.md`, `RESUME-20261005-analog-video-test.md`, and
`RESUME-20261002-release-and-scaler.md`. No applicable `AGENTS.md` was found
in this repository or its workspace ancestors. The October 5 handoff has
conflicting macro/build claims; current sources take precedence. Even BUILD's
description of `--check` retaining a stale build stamp is historical: the
current script invokes `sys/build_id.tcl` before standalone mapping.

No Quartus process appeared in a local `Get-Process quartus*` snapshot. This
does not certify another build host is idle. Recheck the actual selected host
before any future flow. The MiSTer's current guest state was not checked.

## Timing and picture contract

Use a dedicated, fixed TV clock, provisionally **27.000 MHz**, independent
of source PLL reconfiguration. A new PLL is preferable to changing the
704.9 MHz source VCO: its integer C counters cannot produce an exact 27 MHz
tap while preserving the existing source clocks. Check available PLLs and
legal Cyclone V counter/VCO parameters during the subsequent synthesis stage.
Do not use a fabric clock mux or logic-divided clock as a framework PLL input.

At nominal 27 MHz, use 1,716 ticks/line and 858 ticks/half-line. A field is
525 half-lines = 450,450 ticks; two fields are 900,900 ticks. This gives
15,734.2657 lines/s, 59.94005994 fields/s, and 29.97002997 full frames/s.
Reference-clock accuracy and jitter still need measurement; ideal integer
counts do not certify the physical oscillator.

Maintain continuous horizontal phase across the two fields, rather than
restarting H at each source VS. Specify field boundaries and sync by an
absolute half-line schedule. Provide six pre-equalizing pulses, six broad
vertical pulses separated by serration gaps, and six post-equalizing pulses,
each group lasting three lines. The two field origins differ by half a line.
Define `field_id=0` as the field drawing even logical canvas rows. For the
chosen line-23/line-285 aperture this is electrical field 2; electrical
field 1 draws odd rows (`field_id=1`). Spatial parity and temporal field
index are different. This corrects the initial plan's parity assumption;
[BT.1618 section 5.1.2](https://www.itu.int/dms_pubrec/itu-r/rec/bt/R-REC-BT.1618-0-200305-S!!PDF-E.pdf)
explicitly assigns odd image rows to field 1 and even rows to field 2.
The analog generator produces authoritative `csync`, blanking and field
markers; HS/VS helpers for OSD must never regenerate or reset this waveform.

Candidate quantized pulse widths are 127 ticks for ordinary H sync and
serration gaps (4.703704 us), 62 ticks for equalization (2.296296 us), and
731 ticks for broad vertical sync (27.074074 us), leaving the 127-tick gap
in each 858-tick half-line. These targets follow
the System M waveform and nominal durations in
[ITU-R BT.470-6, Tables 1-1/1-2 and Figure 2-2](https://www.itu.int/dms_pubrec/itu-r/rec/bt/R-REC-BT.470-6-199811-S!!PDF-E.pdf).
The current composite-video specification is
[ITU-R BT.1700](https://www.itu.int/rec/R-REC-BT.1700-0-200502-I).

An independent bench must check physical durations and field structure,
not import these RTL constants.

Keep a separate **logical** 640x480, square-pixel, 4:3 picture coordinate
system. Electrical DAC samples are not logical Mac pixels.
[BT.601-7](https://www.itu.int/dms_pubrec/itu-r/rec/bt/R-REC-BT.601-7-201103-I!!PDF-E.pdf)
uses 858 samples/line and 720 digital active samples at 13.5 MHz; that is not
a 720-square-pixel canvas. Do not send 640 consecutive samples at 27 MHz
and expect correct image width.

For the initial analog profile, propose a 1,422-tick picture aperture
(52.666667 us), with 294 ticks total horizontal blanking (10.888889 us).
With H-sync beginning at tick 0: sync [0,127), back porch [127,253),
picture [253,1675), front porch [1675,1716). This is a rounded engineering
choice within the System M analog blanking range, distinct from the wider
BT.601 digital aperture. Distribute all 640 logical columns across that
picture interval with a phase accumulator/nearest-neighbor hold
(`x=floor(sample_in_picture*640/1422)`), accounting for RAM/pipeline latency.
This changes sample representation, not the requested one-for-one placement
in the logical canvas. Later aperture/overscan calibration must preserve
sync and blanking limits.

Use 240 full picture lines per field. A candidate convention is electrical
line labels 23-262 and 285-524, as in the 480-active-line representation in
[ITU-R BT.1618, Table 20](https://www.itu.int/dms_pubrec/itu-r/rec/bt/R-REC-BT.1618-0-200305-S!!PDF-E.pdf).
Model their positions on a single 525-line timeline including fractional
field origins; do not express both starts as an identical integer offset
from a field reset. Blank the unused analog lines. The bench must derive
each field's line positions from that schedule and confirm proper weaving.
The first picture line of electrical field 2 occurs 21.5H after its origin,
and that of field 1 occurs 22H after its origin: the latter is half a line
lower on an ideal vertical scan. Check this physical row ordering in
addition to assembling a software image.

| Mac source | Canvas origin | Canvas occupied region | Borders left/right; top/bottom |
| --- | --- | --- | --- |
| 512x342 (Macintosh Plus and related compact Macs) | (64,69) | x=64..575, y=69..410 | 64/64; 69/69 |
| 512x384 (Quadra 12-inch mode) | (64,48) | x=64..575, y=48..431 | 64/64; 48/48 |
| 640x480 (Quadra 13-inch mode) | (0,0) | x=0..639, y=0..479 | 0/0; 0/0 |

For field row `k=0..239`, `canvas_y=2*k+field_id`. If inside the source
rectangle, read `source_y=canvas_y-origin_y` and `source_x=canvas_x-origin_x`;
otherwise emit picture black. Border pixels remain inside DE. Electrical
blanking remains outside DE and is controlled independently.

The odd 342-line origin reverses source parity: field 1 first shows source
row 0 at canvas row 69; field 0 first shows source row 1 at canvas row 70.
Field 0 has 35 top and 34 bottom border lines; field 1 has 34 top and 35
bottom. Each field carries 171 source rows. The 384-line mode has 24 top and
24 bottom border lines and 192 image rows per field. These are exact checks,
not values to round to even offsets.

## Module boundaries and integration

```text
Mac native RGB/DE/CE/frame markers ----> existing normal video path
                  |
                  +--> capture FIFO --> frame-store writer/owner manager
                                            | DDR adapter
fixed TV PLL --> 525-line timing --> line prefetch/read FIFOs <-- frame store
                       |                    |
                       +--> canvas placement/pixel sampling
                                      |
                              diagnostic pattern selector
                                      |
                          TV-coordinate OSD/compositor
                                      |
                         RGB-to-YPbPr + delayed sync
                                      |
                       analog-board pin/sync-on-Y adapter
```

Proposed reusable units: `tv525_timing`, `tv_test_pattern`,
`video_capture`, `video_frame_store`, `tv_canvas`, and `tv_output_adapter`.
Keep Intel PLL/RAM primitives, MiSTer configuration, DDR addresses, pin
mapping, and OSD transport in platform wrappers. A Plus core supplies the
same stream contract without implementing DAFB or adopting Quadra timings.

Source contract: source clock/reset, pixel CE, RGB888 (monochrome replicated
to RGB), active DE, explicit line/frame markers, and width/height metadata
latched with a frame. Honor CE; do not assume every source clock is a pixel.
Tap Quadra's machine RGB and `mac_de` before `video_freak`, scanlines and VGA
OSD, or expose an equivalent raw stream through `emu_ports.vh`. Define the
selected tap precisely during implementation, including existing auxiliary
overlays. TV mode must not send timing changes back into DAFB VBL interrupts.

TV contract: fixed clock, full-frame/field/half-line markers, canvas x/y,
picture DE, authoritative sync/blanking, and RGB. All controls must share the
pixel pipeline delay through RAM, OSD and conversion. Stream loss, guest
reset, mode changes, and memory starvation must not interrupt TV sync.
Use a black/test picture while reacquiring valid input.

Compose the TV OSD after canvas placement so it stays usable without Mac
frames and is not delayed by the frame store. Audit `sys/osd.v`'s existing
interlace handling before reuse: its DE/line counting and field skipping
cannot be assumed to match the new logical row coordinates. Prefer reuse of
the bitmap/control transport with a field-aware coordinate adapter. Verify
menu text in both fields and on diagnostic/black fallback. Keep normal OSD
behavior and meaningful OSD-open status.

For the passive component cable, reuse `vga_out`'s arithmetic on `clk_tv`
and route `{Pr,Y,Pb}` to physical R/G/B DAC lanes. Feed the timing generator's
composite-sync waveform through the same delay as conversion. Audit board
sync insertion from its actual schematic/revision and measured Y waveform:
`vga_out` itself does not insert a negative Y sync voltage. Confirm the
VGA/SD repurposed low DAC bits, enables, SoG switch, and pin polarity as well
as the primary six DAC bits. Do not merely replace the three RGB assignments.

Current official
[MiSTer CRT configuration documentation](https://mister-devel.github.io/MkDocs_MiSTer/advanced/crttable/)
lists native component mode, `vga_sog`, and the board override switch; newer
Main uses `vga_mode=ypbpr`, while older installations use `ypbpr=1`.
Record the installed Main/configuration instead of changing settings from
memory. The needed electrical result is sync on Y with neutral Pb/Pr during
blanking, whatever settings/pins realize it on this board.

For eventual Y/C or CVBS, clock the encoder from TV timing, recompute
`PHASE_INC` and burst windows for that clock, inhibit burst on required
vertical lines, retain NTSC line/subcarrier and four-field phase continuity,
and verify luma/chroma delay, amplitude, setup policy, bandwidth and mixer
clipping. Existing `yc_out` is reuse material, not a compliance certificate.
For an external encoder, check its accepted sync/reference-clock interface
and whether it inserts any missing pulses. RGB-only output likewise needs
its own cable/display sync convention.

## Buffering choice, ownership, and cadence

| Approach | Benefit | Cost / constraint | Decision |
| --- | --- | --- | --- |
| External-memory completed-frame buffering plus on-chip line FIFOs | Preserves native timing; absorbs phase/rate differences; portable across all three modes; tear-free field pair | DDR arbitration, CDC, more latency and bandwidth | Recommended baseline |
| Source retiming/genlock plus bounded line buffers | Low latency and small memory | Changes source scanout/VBL cadence or requires proven source control; per-core work; can disturb guest behavior/normal video | Possible dedicated-core optimization after the baseline works |
| Fixed native source plus two/few line buffers | Small initial PoC | Cannot bridge arbitrary rates indefinitely; needs a proven occupancy schedule and explicit dropping/phase policy; 24.48 kHz source lines do not align to 15.734 kHz output lines | Reject as general architecture |
| Another read port on emulated VRAM | May avoid stream capture | Core-specific packing/CLUT/stride; concurrent guest writes can tear; M10K replication competes with existing VRAM | Audit only if frame-capture resources fail |

Use three frame slots with one authoritative ownership manager: FREE,
WRITING, READY, DISPLAYING. Publish READY only after a complete valid source
frame and after every memory write is accepted/ordered. Transfer descriptors
with acknowledged mailboxes or asynchronous FIFOs, not independent two-flop
copies of addresses/geometry. Readers never access WRITING storage; writers
never modify DISPLAYING storage. If a newer READY frame replaces an older
one, recycle only the older non-displayed frame. Handle coincident publish,
display selection, and release centrally. Reset/mode change must drain or
invalidate outstanding requests before memory is reused.

At the first field of each output pair, select the latest completed source
frame; hold its descriptor for both fields. If none is ready, repeat the
previous pair. Capture native approximately-60 Hz video while emitting
29.97 complete frame pairs/s: approximately every other source frame is
discarded. This is intentional temporal rate conversion. It gives a stable
weave for desktop text, with approximately 30 Hz motion updates. Selecting a
new source at every field could improve temporal motion but creates different
times in neighboring rows; consider only as a later explicit mode.

At these rates the wait to start displaying a changed source frame can be
roughly one source frame plus one output pair (~17-50 ms), then up to another
33.37 ms for a particular row to be scanned. Measure end-to-end cursor/input
latency; do not promise two-line latency for this design. Drop/repeat counters
and selected frame IDs make cadence observable.

For 640x480: RGB888 is 921,600 bytes/frame; RGBx8888 is 1,228,800;
RGB565 is 614,400. Three RGBx slots occupy 3,686,400 bytes (~3.52 MiB),
so a verified 4 MiB reservation is sufficient for the frames. RGBx is the
first implementation choice for simple 64/128-bit packing and full 8-bit
color preservation. RGB565 is a possible later resource/bandwidth tradeoff,
not an automatic downgrade. Store native rows, generate borders at readout,
and keep a maximum-width stride with geometry in the descriptor.

Worst baseline RGBx traffic at 640x480 is ~73.7 MB/s capture plus ~36.8 MB/s
scanout = ~110.6 MB/s payload. These exclude burst/turnaround overhead and
all Mac/framework clients. Two 640x32 prefetch buffers alone need 40,960 bits;
actual M10K allocation, capture FIFO size and ownership storage must be
reported after synthesis. An entire RGB888 frame is larger than the
device's total embedded memory, even before the Mac uses it.

Prefer the existing 128-bit `vbuf` HPS DDR port at `clk_100m` for the initial
CRT-only memory wrapper. It is normally owned by ASCAL, which is omitted by
the present no-HDMI macro. Its nominal bus width/clock is not a guaranteed
memory service rate. Audit unused-port tie-offs, reset gating, accepted write
beats, read response ordering, address units and byte enables. Reuse the
safe-terminator/startup gate in `sys/sysmem.sv`; the documented truncated-burst
startup defect is directly relevant. Never interrupt a write burst halfway
through a profile switch/reset.

Do not assume the scaler's region at byte 0x20000000 is free: confirm Main's
reservation and ASCAL's complete slot/address map first. Avoid ROM at
0x38000000, the legacy RAM window at 0x30000000, Ethernet around 0x1ff00000,
and all live scaler/HPS buffers. The core's existing 64-bit DDRAM bridge in
`MacQuadra800.sv:1146` services ROM uploads/misses and Ethernet; it has no
general video arbiter. In the combined normal+TV profile, compare sharing
`vbuf` via a burst-level arbiter versus adding the video clients to DDRAM.
Do not add a second master by wiring signals together.

Use asynchronous capture/read FIFOs and complete-line ownership. Prefetch
before a line starts; once emitted, a line must not wait on DDR. Budget
capture FIFO depth against peak source pixels and the measured maximum
service gap. Require no starvation of CPU/ROM/Ethernet or HDMI clients.
If capture overflows, invalidate that whole frame and resume at a frame
boundary. If a scanout line misses its deadline, emit a defined black line
and count an underrun while keeping sync valid; healthy operation requires
zero such events. Repeat the last complete frame on source loss.

## Milestones and pass/fail gates

| Stage | Concrete work after implementation is authorized | Pass / fail |
| --- | --- | --- |
| 1. Timing and diagnostic bench | Add fixed TV timing and patterns in standalone portable RTL, plus a new independent bench; keep old PoC for comparison | At least four fields for the vertical/parity sequence and a longer 120-field run: exactly 1716 ticks/H, 450450/field, 900900/pair; half-line alternation; six/six/six pulse groups with correct widths/gaps; 240 picture rows/field; no active samples in electrical blanking. Randomized reset release; no dependence on any input frame clock. Produce waveform and woven field images. |
| 2. Component/OSD wrapper | Reuse component arithmetic downstream of TV patterns; wire authoritative sync and usable OSD | Independent RGB-to-YPbPr reference agrees with implemented approximation/quantization; grayscale has neutral Pb/Pr; R/G/B bars map correctly; all controls align with pixel latency; OSD is legible in both fields and survives absent Mac input. Verify DAC/pin path, not only internal signals. |
| 3. Synthesis and fit | Freeze inputs, manifest/hash source list, macros, stamp, tool versions and seed; one global Quartus flow; `--check`, then full fit | Correct M10K inference, no unexpected array-to-register expansion, legal PLL topology, constrained TV paths, reviewed CDC, complete RBF and consistent reports. Record per-domain setup/hold slack and ALM/RAM/DSP/PLL totals. Clean timing is the engineering acceptance target. A marginal build requires explicit experimental treatment; the historical -0.916 ns CPU miss is not a validated baseline. |
| 4. Authorized static CRT test | Confirm adapter/board/config; check current screen/guest state; one bounded diagnostic load when menu/safe-shutdown state and user authorization permit | Scope Y over a correct 75-ohm load: H ~63.5556 us, field ~16.6833 ms, correct half-line offset and vertical pulse sequence; appropriate component luma/sync and neutral Pb/Pr. No roll, sync loss, periodic sideways wobble or field slip over a 10-minute static test. No color cast in grayscale, recognizable bars, stable grid. Confirm alternating fields are vertically displaced, not 240p repeated twice. Record TV/cable/settings/RBF hash and photos/measurements. |
| 5. Frame store in simulation | Add memory adapter, ownership, capture, prefetch and canvas; test all three synthetic source sizes | Compare every logical pixel of both fields against a separate coordinate/frame-ID reference, including first/last rows and columns, all border edges, 342 parity, all channel bits and RAM latency. Run independent clock phases/rates (including 60.14 Hz), backpressure, response delays, lost input, mode changes, overflow and reset during bursts. Zero ownership violations/tears; exact documented drop/repeat policy; no timing phase change when input stops. |
| 6. Quadra integration | Connect 512x384 and 640x480 native streams; fit each intended profile; then authorized hardware test | Correct placement and color in both modes; zero video FIFO faults within validated DDR service bounds; moving cursor/window exposes no torn lines or swapped fields; source/VBL/audio timing preserved; OSD usable. Normal HDMI regression if enabled. Required Mac OS/A/UX clean-boot/shutdown and CD audio checks before any normal-core release. |
| 7. Portability and controls | Connect a Plus-family 512x342 source later; optional analog Native/TV-480i selector; overscan/filter controls | Same portable module passes the 342 mapping tests with actual source CE/timing. Toggle does not reset the guest or retarget its clock; switch only after blanking/handshake, with memory ownership drained safely. No fabric clock mux. Normal path still works. |

Diagnostic set: black, white, grayscale ramp, primary/75% bars, a grid with
center circle and edge markers, a field-ID patch, and alternating one-line
patterns. Distinguish natural interlace flicker on thin horizontal detail
from unstable sync. A 640x480 circle provides a geometry check; CRT service
geometry and overscan vary, so perfect visible borders/circles on every TV
cannot be guaranteed. Log clipping first; do not alter electrical blanking
to hide it. A later optional vertical flicker filter (for example 1:2:1)
trades sharpness for reduced twitter and needs extra row reads/buffers.

For amplitude measurements, common consumer component engineering targets
are approximately 0.7 V black-to-white Y and -0.3 V sync relative to blank,
with Pb/Pr centered at their neutral level. Actual DAC DC offsets/clamping
must be included. See
[Analog Devices' video clamping discussion](https://www.analog.com/en/resources/technical-articles/get-a-grip-on-clamps-bias-and-accoupled-video-signals.html).
Use the identified board/output convention for final acceptance limits; do
not add composite 7.5 IRE setup or a color burst to component by assumption.
Digital benches and HDMI screenshots cannot verify RCA voltage, analog color,
or physical field placement. Without measurement equipment, CRT observations
can qualify practical compatibility, but electrical compliance stays unverified.

Before every build check the selected host for all `quartus_*` flows, retain
the normal global wait gate, and leave RTL/QSF/QIP/SDC/build stamp unchanged
until completion. The user's no-commit instruction overrides the older
commit-before-build recipe: use an immutable local manifest/archive and input
hashes instead, without making a commit. Do not overwrite existing RBFs or
fit evidence without preserving their identity. Before hardware testing,
inspect state and use the designated MiSTer only. Never reset/load while a
guest is running, restart its remote-input service, or run reboot/load loops.

## Remaining questions and first implementation target

Known: passive MiSTer Addons component cable; 342-line mode belongs to
Plus-family Macs; current Quadra provides 384 and 480 modes.
Still needed before pin-level integration/hardware acceptance: analog-board
model/revision, effective Main/version/config overrides, `vga_mode` or
`ypbpr`, `vga_sog` and SoG switch state, actual CRT model/input, available
scope/capture equipment, and identity of the earlier successful 480i RBF.
Memory integration additionally needs a verified DDR reservation/service
budget, measured arbitration latency, and current combined-profile resources.
These questions do not block the independent timing/pattern simulation.

The first small implementation target is **Stage 1 only**: `tv525_timing`,
`tv_test_pattern`, and a new timing/pixel reference bench at nominal 27 MHz,
with exported waveform and full-frame reconstruction. It needs no Mac RAM,
DDR allocator, guest boot or hardware load. Acceptance is a correctly woven
480-line diagnostic picture and the independently checked 525-line sync
schedule. Review that result before integrating the component/OSD wrapper,
then fit and measure it before adding Mac capture.
