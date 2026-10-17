# AP68040 faster boot investigation, 2026-10-17

## Hardware baseline

User-confirmed with the current fitted core: timing passes, the ROM executes,
the HDD ends at a flashing question-mark disk, and an installer CD reaches
Happy Mac then repeatedly restarts without an OS loading bar. The user reports
the failures across tested images. PRAM/configuration resets have already been
ruled out as remedies. These observations supersede the earlier fit blocker;
they do not establish an OS boot.

Investigation started on `faster-ap`, commit `b3ff683`. Existing edits to the
integration notes, upstream notes, and RAM testbench were preserved. No Quartus
flow, deployment, or hardware reset was launched.

## Reset and storage evidence

* `quadra800.sv` leaves the CPU's `nresetout` disconnected. The native CPU
  halts on a double fault; that signal does not feed the machine reset.
  The hardware's apparent CD reset therefore needs a trace to distinguish a
  software restart from an externally asserted machine reset. A CPU exception
  can still cause software to restart; disconnected RESET is not proof against
  a CPU defect.
* Full-machine HDD simulation reads block 0, the disk driver at sectors 64–82,
  and partition-map sectors before returning to repeated scans. That is beyond
  total SCSI enumeration failure, but does not establish byte correctness or
  successful execution of a boot block.
* The legacy CPU also returns to scanning with the same simulator, diagnostic
  ROM, and HDD image. This simulation result cannot isolate a faster-core
  regression. The HDD was `pure-mac-series/8.1-v2.hda`; image writes were
  suppressed with `+ignore_scsi_writes`.
* The CD simulation used
  `691-0088-A--Macintosh-CD-Install-Me-First--SSW-v7-1--CD-.toast`.
  It reads CD sectors and driver responses, but has not reproduced the user's
  Happy Mac reset loop. Neither native run asserted a machine reset or a CPU
  double fault through the 500,000,000 simulator-tick limit. These are diagnostic
  runs, not OS-boot acceptance results.
* The parked-I/O adapter regression still passes at fixed and randomized
  latency (2,607 and 3,407 CPU clocks). Its passing synthetic transaction does
  not exclude other replay failures. No shared cause with the hardware symptoms
  has been established.

## Simulator repairs and diagnostics

`sim_main.cpp` previously called the block-device service only when `--disk`
was supplied. A CD-only run therefore did not service even its mount queue.
The service now runs when either `--disk` or `--cd` is present. This is a
simulator fix, not an explanation of hardware boot failure.

`+bootdiag` adds simulator-only records for machine reset transitions, RESET
instructions, ROM entry, synchronous exceptions, double faults, parked bus
cycles, the first four PDMA transactions per command/direction, and command
transfer counts, plus transparent-translation register changes. Exception records include a bounded recent instruction-PC
history. `BOOT` timestamps count rising CPU clocks; the existing host `HB`
timestamps count simulator ticks (two per CPU clock). No FPGA debug packet
format was changed.

`make -C verilator fastboot` now uses the existing ROM selected by `ROM` and
`scripts/prepare_ap68040_boot_rom.py`. The old recipe referenced missing files.
The helper requires the known original Q800 ROM hash, branches at `$40847336`
to the ROM's own warm RAM-test exit, and repairs the checksum. Its changes are
limited to ROM offsets 2, 3, and `$47336..$47339`; the original ROM is untouched.
Use it for diagnosis only. Release acceptance must use the pristine ROM.

The legacy simulator had also lost its optimized internal `core.mem_err` C++
member. Its observer now derives the same data-channel error expression from
the wrapper pins. The existing key/profile/RAM-dump/quit integration check
passes with this repair.

## Macintosh silicon corpus

The relevant bootable fixture is
`SingleStepTests/prebuilt/quadra800-allinone-2026-08-28b.tgz`, not the unrelated
upstream `data040.zip` instruction generator. The archive SHA-256 matches
`prebuilt/SHA256SUMS`:
`91e19a6146e38a48766f2f5e09fe094e0298b3d536422b5a8c3b64192ea88422`.

It contains a 21,020,672-byte HDA and a manifest. The disk boots directly into
CPU → FPU → save/restore → MMU-full → integration, and writes results back
through SCSI. Test a disposable copy: those writes are part of the test. The
manifest identifies each result region; the expected image diagnostic `C` is
`862D7F48`. See the prebuilt README for display requirements and extraction.

`verilator/tb_ap68040_mac_corpus.sv` and
`scripts/test_ap68040_mac_corpus.sh` run the existing
`SingleStepTests/preboot/sim040` payloads through the **production faster CPU
wrapper and wombat_bus32**. They supply the original flat 4 MiB test world,
including the MMU suite's 8 KiB identity page tables. They do not run SCSI or
ROM boot. Results are scored by the existing silicon-oracle scorer with its
documented flat-environment classifications. The runner additionally rejects
missing or malformed rows, since the existing scorer alone can accept a short
matching prefix.

Build the payloads using the existing sim040 Makefile, then run:

```sh
AP68040_MAC_PAYLOAD_DIR=SingleStepTests/preboot/sim040/build \
  bash scripts/test_ap68040_mac_corpus.sh cpu fpu saverestore mmu integration
```

`AP68040_MAC_WORK_DIR` selects an independent output/build directory;
`MAXCYCLES` sets the per-suite clock limit. This investigation built the shared
payload sources with a scratch-local GNU m68k GCC 15.2 cross-compiler; the
normal Makefile defaults to Retro68. No system compiler package was installed.

Results are recorded under `scratch/ap68040_mac_tests/` and
the per-suite `scratch/ap68040_mac_{fpu,mmu,integration}/` directories:

| Suite | Output records | Raw scorer result |
|---|---:|---|
| CPU | 717/717 | 17 reported field differences; investigated below |
| FPU | 270/270 | zero real differences |
| Save/restore | 8/8 | zero real differences |
| MMU-full | 25/25 | zero real differences (24 test rows plus initial-state record) |
| Integration | 1328/1328 | zero real differences (1277 matching field groups, 51 classified golden) |

The CPU raw result is preserved in `score_cpu.log`; it is not reported as a
clean pass. Fourteen flagged fields are seven fixed-address/Mac-low-memory
reads not reproduced by this flat environment. Two flags are `TST.W A0/A6`:
the capture's scratch address is `$63886` (positive low word), while this build
uses `$6C356` (negative low word). The candidate's N=1 is correct for its actual
operand. The misleading test names still refer to an older `$1800` scratch
layout; the test bytes use the current scratch register.

The remaining difference is the `BSR.W / RTD #4` row's exception vector
(silicon 2, candidate 3). That row discards four bytes without reserving a
caller argument, so its later harness RTS loses the caller's return address.
The vector from the resulting invalid return depends on the surrounding stack
and memory environment. A directed adapter-program addition checks a valid
RTD #4 call with a reserved argument and verifies restored SP, as well as both
signs of TST.W on an address register. Fixed and randomized runs pass at
2,801 and 3,667 clocks. This resolves those narrow instruction hypotheses;
it is not evidence of a successful Mac boot.

The Intel packed-RAM full-CPU attempt is unavailable: Verilator rejects mixed
blocking/nonblocking assignments in Intel's supplied `altsyncram` model. That
attempt is not a pass and was not worked around by suppressing the errors.
The separate Icarus RAM-equivalence test remains the appropriate existing check
of that primitive implementation; it passes for both inferred and Intel-model
RAM byte enables and read latency in this investigation.

## Full-machine test-disk boot

The unmodified all-in-one HDA was also run through the complete Mac simulator,
using a disposable writable copy and the diagnostic ROM. It reads its driver,
partition map, and HFS boot blocks over SCSI, reaches Happy Mac, and enters the
boot stub at logical `$00400000`. The first boot-block PDMA words match the
fixture (`4C4B6000 0086D000 00000653 79737465`). This is stronger evidence than
enumeration alone, but not a passing SCSI read/write test.

The stub then clears the screen at PC `$0040009E`. Its framebuffer writes
overwrite physical low RAM with `$FFFFFFFF`, including the `_HwPriv` dispatch
table at `$5420` and the drive queue. It faults at `$004000E0`, followed by
ROM `_HwPriv` jumps through `$FFFFFFFF`. Saved artifacts are
`scratch/ap68040_mac_tests/fullmachine/run.log`,
`ram_snapshot_429709827.bin`, and `screenshot_f512.png` (Happy Mac).

A read-only inspection of the running model at simulator tick 547,490,643
confirmed ITT0/ITT1/DTT0/DTT1 are all zero. The saved ROM mode tables contain
the expected `$F900C060`/`$807FC040` pair for 32-bit mode, but the active table
is the other entry: low-memory `$CB2=0`, `$CB4=$007FDFEC`, `$CB8=$007FDFD8`,
with TC `$C000` and SRP `$01FF6C00`. The screen wipe therefore reaches RAM
through the active page tables. This observation does not by itself establish
a MOVEC or TTR-match defect.

`SingleStepTests/test-blockers.md` finding 26 and
`preboot/common/boot/boot_stub_scsi.s` document this same emulator boot failure
and the emulator-only `BOOT_SET_DTT0=1` build option. A separate emulator image
was tested under `scratch/ap68040_mac_tests/emulator/`. Before adding that
option, its stock boot-block build was verified byte-for-byte against the
committed fixture, including patched payload markers and padding. The original
HDA is unchanged. The emulator variant must not be substituted for a hardware
test of the committed fixture, and this failure has not yet been linked to the
user's hardware HDD/CD symptoms.

The emulator variant passes the previously failing wipe and loads/executes the
CPU payload. At tick 416,584,051 it is at PC `$00041182`, with an intact
`_HwPriv` table. Its RAM snapshot matches 128,451 of the 128,452 payload bytes;
the sole difference is word `$0005F5B0` changing from 0 to 1. The payload itself
contains `MOVE.W #1,$0005F5B0` at offset `$1354`, consistent with initialization
already having executed. This is evidence of payload delivery and execution.
The screenshot is not readable as 8-bpp test text: the simulator ROM selected
DAFB mode 0, while the committed fixture paints 8-bpp pixels.

The bounded diagnostic was stopped gracefully at simulator tick 506,658,817,
after three 16 KiB result batches had been written through SCSI. The disk
contains **175 complete CPU records**, scored against the silicon capture:
2963 matching field groups, 362 classified layout fields, **zero real
differences**. The last batch ends inside the next JSON record, as expected
for a sliced writer stopped before its next flush. Only the 175 complete
records were scored, with the row-count mismatch explicitly preserved in
`scratch/ap68040_mac_tests/emulator/score_cpu_prefix.log`. This is a partial
read/execute/write diagnostic, not a completed all-in-one run or a replacement
for the complete flat-world corpus results above. No simulator remains running.

The user then tested the committed all-in-one HDA on the current fitted core:
**Happy Mac indefinitely, no reset**. This reproduces the simulator's visible
stage, but does not prove that the same low-memory corruption occurs in hardware.
A separate `scratch/ap68040_mac_tests/quadra800-allinone-dtt0-probe.hda` is ready
for the requested comparison. Its boot block sets DTT0 to `$F900C060`, the
framebuffer window from the real-Q800 capture, before any drawing. It leaves
ITT0/ITT1/DTT1 alone. All bytes outside the 1024-byte HFS boot block are verified
identical to the committed fixture; payload checksum `C` remains `862D7F48`.
Probe SHA-256: `7682220e3a5399c05eb0301ac679a1197954fbc9a893c4916b00cbba5ea9c2df`.
This is a diagnostic experiment, not an OS boot fix.

## Completed hardware probe run

The user supplied `20261017_160832-screen.png`, showing the final integration
suite at **DONE**, `passed=1136 of 1328`, `ioResult=0000`, driver `$FFDF`, drive
8, and results base `$0012EC00`. The modified HDA on
`\\192.168.0.165\sdcard\games\MacQuadra800\quadra800-allinone-dtt0-probe.hda`
was copied read-only to `scratch/ap68040_mac_tests/hardware_20261017/run.hda`.
Source and local SHA-256 both equal
`5a1996e3d711a7fd6de6a66af93fe22bbbef7e7a33d243a35683d6a831ada46e`.
Every byte outside the manifest's 1 MiB results region matches the prepared
DTT0 probe. No MiSTer file, core, or running configuration was changed.

All results were split using the existing manifest and splitter. Every
nonempty record parses as JSON, and each suite has exactly the oracle's record
count. Scoring uses the existing real-Quadra captures and default architecture
policy, **without `--flat-env` or `--mask-aexc`**:

| Hardware suite | Complete records | Real differences |
|---|---:|---:|
| CPU | 717 | 0 |
| FPU | 270 | 0 |
| Save/restore | 8 | 0 |
| MMU-full | 25 (24 test rows plus initial state) | 0 |
| Integration | 1328 | 0 |

The scorer still applies its documented classifications: CPU layout 1551;
FPU label 46/layout 400; MMU environment 20/frame 2; integration golden 51.
Raw logs and parsed records are under
`scratch/ap68040_mac_tests/hardware_20261017/`. These are passing corpus
comparisons, not a claim that every possible CPU behavior or OS boot works.

The displayed 1136 is exactly the passing integration simulation's own count.
Both have 1152 nontrapping rows and 176 vector-11 rows. The remaining 16
nontrapping rows disagree with the bench's embedded expected values, while
their actual values and vectors agree with silicon. The older silicon capture
shows 1085 `pass=1` rows; its other 51 expected/pass differences are classified
golden by the scorer. Thus the screen's 192 remaining rows are not evidence of
192 CPU defects.

This run establishes complete SCSI payload loads, chain hops, and result
writes on the fitted hardware with the DTT0 probe. It also removes the 17
flat-world CPU differences as hardware failures: the complete hardware CPU
corpus compares with zero real differences. The original-HDA Happy Mac stall
and this successful probe strongly implicate framebuffer/MMU handoff state in
that test-disk failure. The initial HDD/CD OS-boot failures remain unresolved;
the probe does not establish why the ROM hands off in the observed mode.

The user also supplied
`C:\Users\Elle\Downloads\quadra800-allinone-dtt0-probe.tar.gz`.
Its five payloads match the HDA, but its 1,048,576-byte `Results.jsonl` contains
only zero bytes. It is not the source of the scored hardware result set.
Archive SHA-256: `22b2a84d1d366fe1f3382133cc8ab4a2b579ba1b7b4b85b39005679df65b8d13`.
The result bytes from that archive were preserved separately as
`hardware_20261017/supplied_Results.jsonl.bin` rather than replacing the valid
disk capture.
