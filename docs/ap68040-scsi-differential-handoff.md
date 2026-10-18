# Action handoff: compare legacy/faster CPU boot-device reads

## User's instruction and immediate task

Actual OS boot fails after the pipelined AP68040 `faster` integration. The
user is tired of repeated FPGA builds and narrowly targeted overlays that
have not produced a cause. They explicitly requested a new chat to **action**
a short comparison of boot-device reads using the previous CPU and faster
CPU. Implement and run that comparison, rather than return another plan.

Start by extending `scripts/test_ap68040_platform.py` and
`scripts/fixtures/ap68040_faster/tb_native_platform.sv` into a CPU-driven SCSI
transfer fixture. They already execute short programs through the real
Q800 service logic, bus adapter, SDRAM bridge/controller and chip model.
Currently they disable CD-ROM/SONIC and mount no images; SCSI/HPS traffic is
the concrete missing path to add. No full Macintosh OS boot is needed.

Deliver a repeatable command and a bounded comparison that either exposes
the first differing bus transaction/RAM byte or precisely establishes which
transfer conditions matched. Do not claim a passing synthetic transfer
proves that OS boot works or that SCSI is universally correct.

## Concrete implementation sequence

1. Read the existing platform fixture, `verilator/tb_ncr53c96.sv`,
   `rtl/iosb.sv`, `rtl/ncr53c96.sv`, and the existing simulated disk/CD window
   implementation (`verilator/sim/cd_window.cpp`, `verilator/sim_main.cpp`,
   and `verilator/sim/mac/` where used). Reuse the actual register and HPS
   block-buffer protocols; avoid replacing the SCSI device with the adapter
   bench's synthetic `$F324` register.
2. Add a small guest assembly program that initializes/selects a target and
   performs READ(10) through the real IOSB/53C96 pseudo-DMA path into RAM.
   Derive register ordering and transfer widths from the ROM's path or its
   existing driver-dialect bench, recording that provenance. Supply sectors
   from the known local ISO via the existing image/window behavior. Include
   command completion/status, byte-for-byte destination checking, and a
   strict cycle timeout. First make a minimal one-block control work.
3. Run the same program, image data, platform RTL and host response schedule
   with both CPU integrations. Legacy uses this repository's previous
   `rtl/wombat_cpu.sv` / `rtl/ap68040/rtl/` and `Q800_LEGACY_CPU=1`; faster
   uses `rtl/wombat_cpu_ap68040.sv`, native bridge and imported faster core.
   Do not accidentally compare against a different upstream old-core tree.
   Replace fixture-native hierarchy references such as `dut.cpu.pc` with
   common observed signals as necessary. Keep differences confined to the
   selected CPU implementation.
4. Then exercise the boot-relevant cache/MMU configuration, mixed transfer
   widths/buffer alignment, multi-block boundaries, and delayed HPS response
   while preserving the same host schedule across both runs. Scope the
   matrix to observed/software-used cases, not an unbounded fuzz project.
   Saved ROM state has DTT1 `$500FC040`; in the saved native RAM snapshot,
   both roots map the SCSI page serialized/cache-inhibited. Validate the
   chosen setup against the source/snapshot rather than inventing one.
5. Compare command sequence, access width/address/data, acknowledgements and
   final guest RAM. Stop at the first divergence and reduce it. If there is
   a demonstrated mismatch, fix it and retain the failing-before/passing-
   after regression. If everything matches, report the exact coverage and
   move the investigation to the remaining MMU/exception-recovery contract;
   do not ask for another speculative hardware overlay.

Some legacy/faster behavior may differ legitimately in instruction timing
or prefetch. Compare the software-visible transfer contract, not raw clock
alignment. Earlier bare test-disk SCSI success is useful but does not cover
the ROM/OS's cache/MMU state and transfer patterns.

## Working state and tools

* Workspace `C:/Workspace/Git/MacQuadra800_MiSTer`, branch `faster-ap`.
  Last observed HEAD `2aaf9ab` (`still-shit`). Recheck status; user commits
  concurrently. Work directly in this local checkout, preserving all work.
* Reference CPU `C:/Workspace/Git/AP68040`, branch `faster`, HEAD and fetched
  `origin/faster` `a171fdfe87a6eb192d8840f9bc4d7186e587dcae`.
* **Uncommitted upstream update is already applied** to the vendored CPU:
  `8c778ee` FPU underflow and `a171fdf` FPU exception delivery/frames, plus
  their backend/MMU timing changes. Local RAM mapping and debug exports
  preserved. `rtl/ap68040_faster/UPSTREAM.md` records the new pin.
* Other uncommitted work includes the new platform test/fixtures,
  `docs/ap68040-hardware-20261018.md`, investigation notes and new upstream
  `tb/asm/t_fpexc.s`. Do not discard or re-import blindly.
* Shell PowerShell. WSL needs `require_escalated` (sandbox otherwise returns
  access errors). Tools: Verilator 5.032, Python3, assembler
  `/home/elle/.local/bin/vasmm68k_mot`. Explicit PATH avoids inconsistent
  assembler lookup:

  `wsl env PATH=/home/elle/.local/bin:/usr/local/bin:/usr/bin:/bin python3 scripts/test_ap68040_platform.py`

* Put complex shell commands in script files. PowerShell/Windows-to-WSL
  quoting has caused empty Bash variables; explicit arguments are safer.
  Generated shell scripts must use LF, not Python's Windows-default CRLF.
* Do not spawn subagents, contact Dani/others, run Quartus/synthesis/fits,
  deploy an FPGA artifact, reboot hardware, or start long full-machine OS
  boot simulations. User runs hardware builds. Existing reports may be read.
* No PRAM resets or RAM-size changes as remedies; extensively tried already.

## Existing inputs and evidence

Read `docs/ap68040-hardware-20261018.md` and the end of
`docs/ap68040-boot-investigation.md`. The older
`docs/ap68040-integration-fresh-brief.md` provides background, but its checkout
state and claim that hardware fault PCs are unavailable are stale.

* Known-good retail ISO:
  `scratch/ap68040_os81_cd/installer.iso`, 420542464 bytes,
  SHA1 `7900544de9a3653494262e9b8b1448295d66239d`.
* ROM: `releases/boot0.rom`, pristine 1 MiB Quadra ROM.
* Saved pre-boot native RAM:
  `scratch/ap68040_os81_cd/native/ram_snapshot_255131649.bin`.
  SCSI page descriptors are `$50F06059` under roots `$03FFFA00` and
  `$03FEEA00`; latter also maps logical `$00F06000` there.
  Older native/legacy full-boot runs stopped before boot selection in an
  ADB wait; they did not reproduce the failure. Do not resume them.
* Three recent videos in `scratch/`:
  `2026-10-18 04-14-52.mkv`, `2026-10-18 04-15-41.mkv`,
  `2026-10-18 04-16-18.mkv`. Analysis under
  `scratch/ap68040_diag/hardware_20261018/` (exact-font decode JSON, contact
  sheets, transition logs). The second records vector 2 / format 7 at
  `$0000FC4E`, address `$FFFFB1DF`, SSW `$0545`: **word read**, ATC fault,
  supervisor data. It precedes the later VIA-mirror fault flood. The first
  and third stay in ROM boot/search with recoverable probe events. No
  pointer-capture trigger in these videos.
* Original clip `D:/VODs/2026-10-17 19-51-31.mkv` records
  `$408253CC / $B6DB6DB6 / $0105`, a `MOVEA.L (A0),A0` reading a RAM-test
  pattern as a pointer. Source chain at `$408253C2/C6/C8`. Later
  `$408046AC / $50F81C00 / $0525` faults overwrite LAST. Do not treat the
  earlier pointer case or later VIA probes as an established shared cause.
* A physical cache-inhibit regression was fixed in `d96cfb4`, but the user
  tested it and reports **identical symptoms**. It is not the boot remedy.
  TCI prevents retention but does not itself serialize/limit line reads.
* Serialized I/O source + destination-fault test demonstrates rereading
  side-effecting data after RTE under the CPU's whole-instruction restart
  model. See `scripts/fixtures/ap68040_faster/serialized_io_restart.s` and
  `scratch/ap68040_os81_cd/serialized_io_{control,fault}.log`. WB3S is clear.
  The previous sequential fork deliberately used the same model. This is
  a real contract question, not yet an observed boot cause. Do not set the
  writeback-valid bit alone: stacked PC/commit/continuation must agree.
* The hardware test corpus matched silicon on its covered records.
  Intentional exceptions are successful tests, not evidence the corpus is
  wrong. Whole fault-frame windows were excluded by the scorer, leaving a
  recovery coverage gap. Do not call 192 embedded counter misses CPU bugs.
* Dani's “not a drop-in replacement” remark is relevant context for auditing
  integration contracts; the user does not know its exact intended meaning.
  It is not a diagnosis or permission to contact him.

## Verification already completed; do not repeat without a reason

After the upstream update: 40/40 selected upstream runs pass across five bus
configurations (`t_fpexc`, `t_fpu`, `t_fpu_frames`, `t_fpu_resume`, `t_mmu`,
`t_cache2`, `t_movem_restart`, `t_stld`). Native adapter fixed/random passes
3,093/4,121 clocks. Platform lint passes with existing warnings.

`scripts/test_ap68040_platform.py` passes pointer-chain alignment/cache sweep
(102,936 clocks), `t_fpexc` (8,583), `t_fpu` (108,921), `t_stld` (402,936),
each with zero SDRAM chip protocol errors and under two seconds simulated
execution walltime after compilation. Results in
`scratch/ap68040_native_platform/`. These use portable CPU RAMs and no disk
traffic; do not extrapolate to boot compatibility or claim fitted Intel RAM
coverage. The older forced-overlay scratch fixture was broken under this
Verilator; the checked-in fixture correctly uses normal ROM startup.

The existing 04:00 TimeQuest report has nonnegative listed setup/hold slack
and no unconstrained clocks; this is not proof of all I/O timing or loaded
artifact identity. No current root cause or justified OS boot fix exists.
