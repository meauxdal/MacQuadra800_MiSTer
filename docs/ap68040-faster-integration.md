# Q800 CPU replacement, 2026-10-17

The default Quartus project and full-machine Verilator simulator now select
Adam Polkosnik's pipelined AP68040 `faster` core, pinned at
`ab4d83d36c33ea6bc5d0bbf19feb5df11a8de892`. This replaces the sequential
AP040 fork and its experimental integer pipeline in the active source list.
The previous CPU sources and wrapper remain available for comparisons.

This is an integration candidate, not a hardware-validated release. Earlier
Mac OS/A/UX boot results and utilization numbers in this repository describe
the previous CPU. Do not transfer them to this candidate.

## Configuration

The processor and bus retain the platform's 33 MHz clock. `bclk_en` receives
the platform CE; the CPU pipeline itself runs on every processor clock, as
upstream specifies. This is not an upgrade to a 60 MHz processor clock.

The full MMU, instruction/data caches, and FPU are enabled. Optional area
features `FPU_PIPE`, `LOOP_PRED`, `EARLY_RES`, `DC1_ATC`, and `SKID` use the
upstream top-level defaults (zero); `DIV_STEPS=2`, `FPU_REVISION=$41`.
The old AP040 experimental-pipeline macros are inactive.

## Native bus adapter

`rtl/wombat_cpu_ap68040.sv` instantiates the native CPU and
`rtl/wombat_ap68040_bus.sv` translates its bus pins to the existing Q800
right-aligned transaction port. The existing `wombat_bus32`, physical
decode, SDRAM bridge, retained-line paths, and peripheral ports are reused.
The new CPU owns its MMU walks and cache writebacks, so the platform's old
separate table-walker request is tied low. The old external CPU store buffer
is not instantiated; the new CPU owns its buffering and ordering.

The adapter converts byte/word data between native byte lanes and the Q800
transaction format. TBI is asserted: a CPU line transfer becomes four
longword transactions, with the CPU handling wraparound. True contiguous
native bus bursts are a possible later optimization. Interrupt/breakpoint
acknowledge cycles terminate locally; interrupt cycles autovector. Bus
errors return TEA, and the existing HPS-aware 24-bit timeout budget remains.

TCI enforces the platform's physical cacheability: RAM (`$00000000` through
`$3FFFFFFF`) and ROM (`$40000000` through `$4FFFFFFF`) permit caching; other
physical windows inhibit cache allocation. The initial native wrapper tied
TCI inactive, losing this restriction from the previous wrapper. A directed
test demonstrated a stale second read from a changing device register with
the data cache enabled and TC/TTRs off. It now checks both I/O and VRAM.
TCI prevents retaining the fetched line; it does not suppress the remaining
line-transfer beats or replace software's serialized/cache-inhibited page
attributes. This repair is not yet evidence of successful OS startup.

SONIC requests first withdraw the CPU's bus grant. After the CPU releases
the bus, DMA runs through its SC=01 snooper. A dirty cache supplies a DMA
read or absorbs a DMA write. Other transfers use the existing platform DMA
memory port. Partial writes are split into enabled-byte snoop cycles, so
arbitrary byte-enable masks preserve untouched dirty-cache data.

An HPS transfer can park a SCSI access while Main waits for SONIC DMA. The
adapter retries that native CPU bus cycle, keeps its original platform
transaction alive, and saves its eventual completion. SONIC can then use
the platform's existing side-DMA path. The CPU's replay receives that saved
completion without executing the I/O operation twice. Locked sequences and
the tail of a burst-inhibited line are never retried this way.

## Simulation and checks

From WSL/Linux, with Verilator 5 and `vasmm68k_mot` available:

```sh
bash scripts/test_ap68040_faster.sh
cd verilator
make -j8
./obj_dir/Vemu --headless --no-cpu-trace --hist --max-cycles 20000000
```

The simulator chooses the ROM present in `releases/` (`boot0.rom` or
`quadra800.rom`); override with `make ROM=/path/to/rom` if needed. Its Main
CD-ROM support dependency remains the one described by `sync_main_mac.sh`.

`make LEGACY_CPU=1` selects the old CPU and builds into `obj_dir_legacy`.
Legacy internal-state profilers (`--cpu-profile`, `--speedometer-observe`,
and the old CPU-state profiler) reject use with the new CPU; their state,
cache, and dispatch definitions do not describe the pipelined processor.
Normal GUI display, PC traces, register display, disk service, screenshots,
and PC histograms remain available. Native instruction completion is sampled
from `dbg_retire`; the architectural-register display mirrors WB writes.
The hardware debug packet currently retains PC and PST; old sequencer/opcode
fields, CACR/VBR debug outputs, and the second packet are unavailable (zero).

The directed adapter test exercises byte/word lanes, misaligned longwords,
FPU arithmetic, restart after a bus error, autovector interrupts, copyback
cache DMA reads, partial writes into dirty/clean lines, and DMA during a
parked longword I/O access. It asserts that the parked operation executes
once. Fixed-latency and randomized-latency runs are both required.

To run upstream's 29 programs in all five bus configurations using the
same CPU options as Q800:

```sh
cd rtl/ap68040_faster
export VASM=$(command -v vasmm68k_mot)
export DEFS='+define+AP_FPU_PIPE=0 +define+AP_LOOP_PRED=0 +define+AP_EARLY_RES=0'
JOBS=4 bash tb/run_tests.sh
```

Upstream's standalone area/timing results are in its README and STATUS.
Q800 area savings require a successful full-machine fit and comparison
with a fixed baseline. Release validation still requires Mac OS 8.1 Finder
and clean shutdown, A/UX multiuser boot and shutdown, and Ethernet/SCSI
traffic together on hardware.

## Initial validation results

* All 145 upstream program/bus-configuration runs pass, plus the exhaustive
  decoder check, with the final RAM compatibility change.
* The new adapter bench passes at fixed latency (2,607 clocks) and random
  latency (3,407 clocks).
* The full GUI/headless simulator compiles. A ROM run using
  `--max-cycles 100000000` clears the overlay and progresses through checksum
  and RAM-test code without a CPU halt. This is not an OS boot result.
* Full-machine Quartus 17.0.2 Analysis & Synthesis succeeds with zero errors.
  The integration disables automatic gated-clock conversion to retain the
  synchronous-clock structure of the native CPU. The fitter was stopped
  after detecting a separate active VideoBrain fit, respecting BUILD.md's
  one-global-flow rule. Area, timing, and an RBF remain pending; existing
  `output_files` fitter summaries may belong to earlier builds.

Local logs: `scratch/ap68040_faster_upstream/results.log`,
`scratch/ap68040_faster_integration/results.log`,
`scratch/ap68040_faster_sim_build.log`,
`scratch/ap68040_faster_boot_long.log`, and
`quartus_build_ap68040_faster_{map,fit}.log`.

## Combinational-resource overflow follow-up

The initial candidate failed fitting with 90,342 combinational nodes against
the device's 83,820-node limit. Passing Analysis & Synthesis did not establish
that the design would fit.

The CPU's inferred byte-enabled memories appeared as separate byte-wide
RAMs. Q800 now enables `AP68040_ALTERA_RAM=1` in its `.qsf` to implement
these as explicit byte-enabled M10K slices. An isolated 64x32 slice fits in
one M10K. The normal portable simulation path remains available.

`bash scripts/test_ap68040_ram.sh` checks the inferred and Intel-model
implementations against a reference memory. The twelve configurations cover
1/2/3/4/16-byte words, both output-register options, both CPU cache depths,
partial writes, read/write collisions, and output clock enables. Both
implementations pass. Set `QUARTUS_SIM_LIB` to the installed
`quartus/eda/sim_lib/altera_mf.v` when using another installation path.

The full Q800 rebuild with packed RAM was stopped at the user's request.
The user will start the next FPGA build. The full-core resource reduction
and timing are not yet verified; the earlier synthesis result and test
results above predate this packed-RAM synthesis option.
