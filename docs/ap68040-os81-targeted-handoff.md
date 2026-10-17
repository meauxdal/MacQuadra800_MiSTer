# Targeted handoff: diagnose actual Mac OS boot failure

## Objective and user constraints

Get an actual Macintosh OS boot working with the pipelined AP68040 `faster`
integration. Use the Mac OS 8.1 retail installer's Sad Mac as the concrete
current reproduction. Obtain the faulting PC/address/status, isolate the cause,
and implement a justified fix. A passing CPU corpus is not completion of the
OS-boot objective.

The user explicitly requested a fresh, seeded, targeted chat as the context
approached compaction. They run FPGA builds themselves. Do not run Quartus,
synthesis, fitting, bitstream generation, hardware deployment, or hardware
reboots. Read-only access to the MiSTer share has been used successfully.
Do not send messages to Dani or anyone else. Do not spawn subagents by default.

**PRAM has been reset many times. Multiple RAM sizes have already been tested.
All actual OS boots fail across images. These are not proposed remedies.**
Matching saved state/RAM in simulation only controls the reproduction. A user
comment about importing Q800 persistence was retracted: it belonged to the 605
chat and is not work requested here.

## Repository and environment

* Workspace: `C:\Workspace\Git\MacQuadra800_MiSTer`, PowerShell.
* Branch `faster-ap`; current HEAD `a20d04c` (`faster-check-in-1`). The user
  committed earlier investigation changes while this chat ran. Recheck status;
  do not assume the earlier HEAD `b3ff683` is current.
* At handoff, only `docs/ap68040-boot-investigation.md` and `verilator/sim.v`
  have uncommitted edits. Preserve them. This handoff file is newly added.
* Reference checkout `C:\Workspace\Git\AP68040`, branch `faster`.
* No AGENTS.md found in the searched repository paths.
* WSL `/mnt/c/Workspace/Git/MacQuadra800_MiSTer`. WSL commands have needed
  `sandbox_permissions=require_escalated` because the normal sandbox gives
  E_ACCESSDENIED; automatic review has allowed local simulation commands.
* Verilator 5.032, GCC, Python3 in WSL. No system compiler packages installed.
* Avoid Bash `$variables` embedded in PowerShell command strings: PowerShell
  expands them. Use scratch `.sh`/`.py` scripts or direct WSL commands.

## Hardware evidence

Current fitted build passes timing and runs the ROM. Earlier HDDs chime, show
gray, then flashing question mark. Some CD attempts reach Happy Mac, retain a
responsive mouse while waiting, then fail and restart. **Actual OS startup
always fails.** The latest screenshot is a separate test of the same FPGA
build: `\\192.168.0.165\sdcard\screenshots\MacQuadra800\20261017_163727-screen.png`,
Sad Mac **0000000F / 00000001**, booting Mac OS 8.1 retail universal ISO.

This code denotes System Error ID 1, bus/access error; it does not provide PC,
fault address, or SSW and does not establish the underlying cause. Apple's
primary System Error Handler reference identifies ID 1 as invalid memory
reference: https://developer.apple.com/library/archive/documentation/mac/pdf/Operating_System_Utilities/System_Error.pdf

The user's exact ISO is
`D:\MiSTer\Macintosh\Mac OS\Apple SSW and Mac OS\8\MAC_OS_8-1_RETAIL.ISO`.
SHA1 **7900544de9a3653494262e9b8b1448295d66239d**.
We copied the same file from
`\\192.168.0.165\sdcard\games\MacQuadra800\Macintosh\Mac OS and SSW\MAC_OS_8-1_RETAIL.ISO`
to `scratch/ap68040_os81_cd/installer.iso`; SHA1 matches exactly. Size
420542464, SHA256 `a9e19e2da7c4ad7552beb3eee2609dbe88c3392fad6e98e1490088b326e5e26c`.

Hardware `boot.rom` and `boot0.rom` both match the pristine local Q800 ROM:
SHA256 `7d9cb8c3bae0e26171adf9f24bedf10bf6371ae3c9bdbcdfd3b94e5350099fb6`.
Saved OSD config `...\config\MacQuadra800.CFG` starts `08 10 00 00`, so
bits4:3 select 64 MiB. That is only the current matched case; other sizes fail.

## Two RUNNING local reproductions — take ownership

Both were started at about 17:08 EDT, 2026-10-17. They are still running and
must be monitored/finished or stopped deliberately. Do not start duplicates.
They use immutable copied binaries, the verified ISO, 64 MiB (`+ram=1`), and a
read-only snapshot of current hardware PRAM. CD only, no HDD attached in these
initial simulator cases; exact hardware disk attachment is not established.

* `scratch/ap68040_os81_cd/native/run.log`, working directory `native/`,
  executable `native/Vemu` — faster CPU, new exception/TTR diagnostics.
* `scratch/ap68040_os81_cd/legacy/run.log`, working directory `legacy/`,
  executable `legacy/Vemu` — old CPU, same platform/ISO/PRAM.
* Launch script: `scratch/ap68040_os81_cd/run_repro.sh native|legacy`.
  Do not rerun until existing processes are finished.
* Common command: `./Vemu --headless --no-cpu-trace --cd ../installer.iso
  +rom=../../ap68040_fastboot.hex +ram=1 +pram=../pram.hex +bootdiag
  --control control.txt --max-cycles 800000000`.
* The prior chat's exec session IDs are 87992 (native), 45741 (legacy), but
  they may not be usable across chats. Use WSL `ps` and `/proc/PID/cwd`.
  At seed creation native PID was955 and legacy PID973; verify cwd before use.
* BOOT timestamps count rising CPU clocks. HB/main_time count simulator ticks,
  two per CPU clock. The 800M cap is simulator ticks, not CPU clocks.
* At ~17:12 EDT native was around 140M ticks, legacy 190M ticks. Neither had
  reproduced the reported installer Sad Mac yet. Native is logging ROM TTR
  changes; its last TTRs cycle between 0 and F900C060/807FC040 through explicit
  ROM `_SwapMMUMode` code at 40803F60..70. SRP values 03FFFA00/03FEEA00.
* `control.txt` files initially empty and can be appended to from PowerShell:
  `shot` (captures next frame), `ramdump 64` (64MiB raw physical RAM), `quit`.
  Append each command as its own line. **Avoid queuing a huge `wait`**, since
  that also delays later quit/snapshot commands until consumed.
* Both early 32MiB runs were stopped before boot-device access and archived as
  `native/early_32mb.log`, `legacy/early_32mb.log`. They are not matched runs.
* `scratch/ap68040_os81_cd/stop_repros.py` can SIGTERM only these local sims
  after validating exact cwd/command line, if normal control cannot stop them.
* Current native/legacy builds both completed successfully with optional PRAM
  preload. Logs `build_native.log`, `build_legacy.log` in the same directory.

PRAM snapshot: `hardware.nvr` in that scratch folder, 512-byte sector SHA256
`b584138207874a17e61ba68e0f1ac3f56fd3e1edec9483c9cd0daa0e97610b84`.
`pram.hex` is the first 256 bytes, as hardware's host loader uses. The new
uncommitted sim.v option `+pram=<hex>` loads that array before clock 0; otherwise
the previous zeroed simulator default remains. No hardware PRAM changed.

The diagnostic ROM `scratch/ap68040_fastboot.rom` / `.hex` skips only the long
RAM test via its existing warm exit and repairs checksum. Helper
`scripts/prepare_ap68040_boot_rom.py` strictly checks original hash. Changed
offsets are 2,3,47336..47339. This is not pristine-ROM acceptance and was never
deployed on hardware. No installer image modification was made.

## Existing diagnostic tools and likely useful next steps

`+bootdiag` in sim.v logs synchronous exceptions, recent 16 retired PCs, machine
reset edges, RESET, double fault, parked native bus requests, TTR changes, first
four PDMA words each direction per command, and transfer counts. A-line and
real IRQ entries are filtered. Expected NuBus probe bus errors at PC40805F04
are normal; distinguish them from the fatal boot fault. Confirm a screenshot
and preserve RAM at the relevant failure. Do not call a non-reproduction a fix.

The ROM's default vector2 target in preserved RAM is **408026F0**, vector3
408026F2, etc. Those entries BSR to **408026A0**, then common handler2736.
It saves register context to lowmem C30..C74 and an exception stack pointer at
C6C. `scratch/boot_rom.dasm` is a mostly linear disassembly, sometimes misaligned;
use `scratch/boot_disasm <binary-ROM> <hex-start-offset> <hex-end-offset>` for
correct local decode. Use `scratch/ap68040_fastboot.rom` for this, not the
nonexistent `verilator/quadra800.rom`. Both tools and sources already exist.
`--stop-at-pc lo,hi` is supported by simulator and prints registers/DrvQ, then
exits; the existing running commands did not set it.

Hardware `SCSI_TRACE` is compiled OUT in current QSF. Do not run
`scripts/scsi_trace.sh` by default: it deploys/reboots unless capture-only,
and tracing cannot work on the current non-trace bitstream anyway. No hardware
CPU debug bridge is attached; top-level `m_debug_status` is otherwise unused.

Useful inference discipline: passing ISA/MMU/FPU corpora does not cover full
OS startup, every MMU mapping, every cache/I/O interaction, or CD-specific
driver paths. Need the actual first failing operation, then a focused fix.
The mouse working during CD wait means that path remains alive; no reason to
assume a complete CPU deadlock. RESET output is disconnected from machine reset,
so apparent restarts may be software; diagnose rather than assume.

## What has ALREADY passed — do not redo without a change requiring it

User ran the committed all-in-one test HDA: Happy Mac indefinitely. Simulator
reproduced low-RAM corruption when its boot stub wipes F9001000 while TTRs are
0. A separate probe inserts DTT0=F900C060 before drawing, all other disk bytes
outside 1024-byte boot block unchanged. On hardware this probe completes all
five suites, SCSI loads/chain hops/result writes, `ioResult=0000`, DONE.

We read a stable complete disk from MiSTer, verified source/local hash and
that only the 1MiB results region changed. Every row parses and counts match.
Against the repository's real-Quadra captures, default scorer policy and
**NO --flat-env / --mask-aexc**:

* CPU 717 records: zero real differences (layout classifications).
* FPU 270: zero (label/layout).
* Save/restore 8: zero.
* MMU-full 25 records (24 tests+initial state): zero (environment/frame).
* Integration1328: zero (51 golden classifications).

Screen `passed=1136 of1328` is expected for this comparison: 176 vector11 rows
plus16 embedded-expectation mismatches not counted as passes; actual results
and vectors match silicon. Do not label 192 CPU failures. The older oracle
counter is1085, with51 golden-model differences handled by scorer.

Evidence: `scratch/ap68040_mac_tests/hardware_20261017/`, logs `score_*.log`,
parsed JSONL under results/, HDA SHA256
`5a1996e3d711a7fd6de6a66af93fe22bbbef7e7a33d243a35683d6a831ada46e`.
Verified shareable ZIP there: `quadra800-hardware-results-20261017-verified.zip`.
User-provided tar.gz had a zero-filled Results.jsonl (all five payloads match),
so it is NOT the data used for those scores; we recovered actual results from
the mutated HDA. No need to request another hardware corpus run.

Complete flat-world sim corpora also ran; CPU had17 harness/environment
differences resolved by the actual hardware run above, other suites zero.
Focused adapter tests (valid RTD#4 argument/stack, both TST.W An signs,
PDMA parking/retry, cache/DMA) pass2801/3667 clocks fixed/random.
RAM byte-enable/read-latency equivalence passes inferred and Intel models.
Intel packed-RAM full-CPU Verilator model is unavailable due vendor mixed
blocking/nonblocking assignments; don't claim it passed. Hardware corpus on
the actual fitted core is the relevant evidence.

Earlier diagnostic HDD8.1 and CD7.1 simulations read drivers/partition maps but
did not boot OS; legacy HDD also rescanned. They cannot isolate this new
8.1-CD failure. Logs under scratch/bootdiag_{hdd,cd,legacy_hdd}/.
Simulator CD-only service bug was fixed: BeforeEval/AfterEval now run if either
disk OR CD present. Legacy observer compile repaired from optimized mem_err
wire to its equivalent wrapper input expression. These changes are committed
in a20d04c. Full narrative: `docs/ap68040-boot-investigation.md`.
