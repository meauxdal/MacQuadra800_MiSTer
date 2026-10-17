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

## Mac OS 8.1 retail installer: new Sad Mac

The user supplied `20261017_163727-screen.png`: **`0000000F / 00000001`**
while attempting to boot the Mac OS 8.1 retail universal installer ISO.
They explicitly confirm **the same FPGA build, a new test**. This is a new
observation alongside the earlier CD restart symptom and the passing probe
corpora; it does not supersede those results.

The minor code is System Error ID 1, a bus/access error. Apple's
[System Error Handler documentation](https://developer.apple.com/library/archive/documentation/mac/pdf/Operating_System_Utilities/System_Error.pdf)
identifies ID 1 as an invalid memory reference. The screen does not provide
the faulting PC, address, or 68040 fault status, and cannot distinguish an
MMU translation fault, a platform bus fault, or an invalid pointer caused by
an earlier error.

The user's exact installer is
`D:\MiSTer\Macintosh\Mac OS\Apple SSW and Mac OS\8\MAC_OS_8-1_RETAIL.ISO`,
SHA-1 `7900544de9a3653494262e9b8b1448295d66239d`. A read-only-source copy
from the existing MiSTer image share matches that SHA-1 exactly:
`scratch/ap68040_os81_cd/installer.iso`, 420,542,464 bytes, SHA-256
`a9e19e2da7c4ad7552beb3eee2609dbe88c3392fad6e98e1490088b326e5e26c`.

To reduce a known simulator/hardware difference, `verilator/sim.v` now accepts
optional `+pram=<byte-hex-file>` before the first simulated clock. This loads
the first 256 bytes of a saved `.nvr` sector, as the hardware's existing host
loader does. Absent that option, the original zeroed-PRAM behavior remains.
No hardware PRAM was changed or reset. The read-only snapshot used here is
`scratch/ap68040_os81_cd/hardware.nvr`, SHA-256
`b584138207874a17e61ba68e0f1ac3f56fd3e1edec9483c9cd0daa0e97610b84`.
Faster and legacy full-machine simulator reproductions use the same ISO,
saved PRAM, and diagnostic ROM, initially with only the CD attached.
The saved hardware OSD status starts `08 10 00 00`; bits 4:3 select 64 MiB.
Both reproductions therefore use `+ram=1`. The hardware corpus's initial SRP
also reflects a 64 MiB machine. Early 32 MiB simulator starts were stopped
before boot-device access and retained as `early_32mb.log`; they are not the
matched reproduction. Both hardware ROM files (`boot.rom` and `boot0.rom`)
match the pristine ROM hash required by the diagnostic-ROM helper.

The user additionally confirms that multiple RAM sizes have already been
tested and that PRAM has been reset numerous times. The Sad Mac is one of
several failure modes: other CD attempts keep the mouse responsive while
waiting, then fail and restart. Actual OS boot always fails. RAM size and
PRAM resets are therefore not proposed remedies. The matched 64 MiB/PRAM
simulation is a reproduction control, not evidence that either setting causes
or fixes the hardware failure. The objective remains successful OS startup;
the passing bare-boot corpus does not satisfy that objective.

## Targeted follow-up: stop full-boot waiting and audit exclusions

The two seeded 64 MiB CD-only runs were stopped deliberately, with logs,
RAM snapshots, and gray-screen screenshots preserved in
`scratch/ap68040_os81_cd/native/` and `legacy/`. Native stopped at tick
255,131,649; legacy stopped around 340M ticks. Both were still before
boot-device selection, waiting in ADB discovery at `$4080A870`. Earlier
successful test-disk simulation spent ticks 220M..380M in the same ROM wait
before advancing. These runs were stopped too early to establish a stall;
neither reproduced the installer Sad Mac.

A replacement instrumented run in `adbdiag/` was stopped around 70M ticks
when the user redirected the investigation away from waiting through full
Macintosh boot simulations. Its optional ADB trace code was removed again.
All three logs end with the simulator's normal exit histogram. No hardware
build, deployment, or reboot occurred. The earlier optional PRAM loader and
all existing checkout changes remain.

A direct raw-result audit (`scratch/ap68040_os81_cd/audit_raw_results.py`)
confirmed that **all recorded exception vectors** match the real-Quadra
captures in CPU, FPU, MMU-full, integration, and save/restore. Integration's
raw `actual` values all match, without scorer normalization: its 192 `pass=0`
rows comprise 176 vector-11 rows and 16 FPIAR writes expecting `$12345678`
but reading `$5678`, also the silicon value. This is evidence about those
recorded results, not universal CPU correctness.

The audit also exposed a significant limit of the scorer: the two MMU fault
frame windows are excluded wholesale. Both candidate format-7 frames have
SSW `$0405`, versus silicon `$0485`; bit 7 is explicitly undefined in
MC68040UM section 8.4.6.2, so that difference is not a defect. The candidate
has clear writeback-valid fields, whereas the silicon capture has WB3S and
WB2S `$0085`. Backend code explicitly uses an instruction-restart model with
WB3S clear (`ap68040_backend.sv`, exception entry). This difference warrants
focused recovery checks; it has not been tied to OS startup. Describing the
entire excluded frame as only relocated PCs would be incorrect.

A scratch-only focused adapter program, `fault_restart.s`, tested a bus-error
on the destination of `MOVE.L (A0)+,(A1)+`, followed by handler RTE. It verified
one handler entry, both address registers incremented exactly once, and the
trace shows the intended `$11223344` destination write after retry. It passes
in 0.009 seconds using the existing adapter-test executable. This checks the
simple restart path only, not silicon writeback-frame equivalence, an
OS-style writeback handler, or successful OS boot. No speculative CPU fix was
made. The actual installer faulting PC/address/status remain unavailable.

Manual: https://www.nxp.com/docs/en/reference-manual/MC68040UM.pdf,
sections 8.4.6.2 through 8.4.6.7 (SSW, writebacks, RTE semantics).

## Fresh contract audit: physical cache inhibit

The corpus includes intentional exception cases. A trapping row is successful
behavior when its recorded vector and state match the silicon oracle; its
embedded display counter is not itself that comparison. Embedded expectation
differences also do not invalidate the corpus. The complete hardware capture
remains useful evidence for its covered paths, with the fault-frame comparison
limits described above.

Source comparison found a concrete integration regression. The previous
`wombat_cpu.sv` applies a physical cacheability restriction before its cache:
RAM `$00000000..$3FFFFFFF` and ROM `$40000000..$4FFFFFFF` permit caching;
I/O, VRAM, registers and NuBus do not. The native wrapper instead tied TCI
inactive. Software TC/TTR/page attributes were therefore the only restriction
on allocation, and permitted device reads could remain in the CPU cache.

A short addition to the existing adapter program enables the data cache with
TC and TTRs still zero, then reads a synthetic changing register at physical
`$5000F380` twice. Before the fix, only the first read reaches the platform;
the second returns the cached first value and the program fails. The trace is
`scratch/ap68040_faster_integration/io_before.log`. The regression also checks
two changing reads at `$F900F380` to exercise VRAM's physical window.

`wombat_cpu_ap68040.sv` now drives native TCI from the physical bus address,
inhibiting allocation outside RAM and ROM. The unchanged native CPU samples
TCI with the first TA of a line transfer. The final directed program passes
at fixed latency (3,093 clocks) and random latency (4,121 clocks); both runs
also retain the existing RAM copyback, dirty/clean DMA, lane, fault-restart,
interrupt and parked-I/O checks. Log: `io_after.log` in the same directory.
Each simulated execution takes under 20 ms after compilation.

This is a demonstrated stale-device-data fix, **not a demonstrated OS boot
fix**. TCI does not prevent the remaining beats of a line transfer and does
not supply serialized ordering. Software must still select suitable cache
modes for side-effecting devices. MC68040UM sections 5.4.5 and 7.4.2 specify
these limits: https://www.nxp.com/docs/en/reference-manual/MC68040UM.pdf.

Existing evidence further limits its causal significance. In the saved
`native/ram_snapshot_255131649.bin`, the page descriptors for logical
`$50F06000` are `$50F06059` (CM=2, cache inhibited/serialized) under **both**
saved roots `$03FFFA00` and `$03FEEA00`. The latter root also maps logical
`$00F06000` to that same physical I/O page. Earlier ROM trace entries set
DTT1=`$500FC040`, also cache inhibited. The missing external inhibit cannot
be blamed for stale SCSI reads in those documented states. Later OS states
are not captured. No full boot simulation or hardware build was started.

Remaining contract questions, ordered by evidence rather than a claim of one
shared cause:

* Fault recovery remains a material coverage gap: the scorer excludes whole
  format-7 frame windows, and the simple RTE test does not exercise an OS
  handler's writeback processing. No observed OS fault frame is available.
* Physical TCI now prevents device-line retention, but the old wrapper's
  pre-cache inhibit also avoided speculative line reads. A side-effecting
  device accidentally mapped cacheable can still receive four line beats;
  the new regression does not establish safe access width in that case.
* The native DMA snooper/parking adapter has short passing directed coverage,
  not an exhaustive coherency proof. Its relevance depends on whether SONIC
  is active during a failing attempt; it is not a justified universal cause.

The native interface requires an explicit integration contract. Passing
instruction tests does not establish that every guarantee formerly supplied
by the old wrapper has been carried across.

## Hardware follow-up: TCI did not change the failures

The user tested the physical-inhibit candidate and reports **identical
symptoms**. HEAD at the follow-up is `d96cfb4` (`cpu: restore physical cache
inhibit`). No exact hardware artifact hash was supplied in this report.
The stale-device-read regression remains valid, but the change is not a
remedy for the reported OS failures and is no longer a leading explanation.

### A narrower fault-recovery reproducer

`scripts/fixtures/ap68040_faster/serialized_io_restart.s` uses DTT0
`$500FC040` to make a synthetic device register serialized/cache-inhibited,
then executes `MOVE.L (A0),(A1)+` from that register. A no-fault control writes
value 1 once, and its next register read returns 2. With an injected bus error
on the destination write, the native frame has WB3A=`$F400`, WB3D=1, but
WB3S=0 and PC points back to the MOVE. The handler can complete an ordinary
longword WB3 when V is set; this frame advertises none. RTE therefore repeats
the source read, consumes value 2 and writes 2 instead of 1. The next device
read returns 3 and the test fails. Both runs finish in milliseconds.

Logs: `scratch/ap68040_os81_cd/serialized_io_{control,fault}.log`; scratch
runner: `run_serialized_io_restart.sh` there. Assemble the fixture without a
define for the control, or with `-DINJECT_FAULT=1` for the failing case, then
run it through the existing directed adapter executable with `+trace`.

This establishes a consequence of the restart model that a RAM-source test
cannot expose. MC68040UM 7.7 discusses serialized device reads, and 8.4.6
specifies software completion of pending writebacks. It does **not** establish
that such a destination fault occurs during these OS boots. The previous
sequential fork also deliberately cleared WB3S and restarted instructions
(`ap040_core.v`, `aerr_word`); the source choice is not unique to the faster
integration. Correcting the model requires coordinated frame contents,
stacked PC, register/CCR commit and continuation behavior; merely setting V
would cause handlers to perform a write and the restart to perform it again.
No such architectural change was made on this evidence alone.

### Capture the real failing attempt

The user selected an on-screen overlay for hardware evidence. The new optional
OSD **CPU diagnostics** observer records selected fault PC/address/SSW, a
first fault after low-address execution, current PC/bus state, machine reset
count and re-entry at the known ROM startup address. Captures survive guest
resets. [Usage and field definitions](ap68040-hardware-diagnostics.md) explain
the filters, boot-stage heuristic and reset distinction. The observer changes
no CPU recovery or bus behavior. Directed capture/CDC/reset tests and native
event checks pass; no hardware build or full boot run was started.
