# Same-cycle NOP cancellation consumed SCSI PDMA data

The faster CPU had a reproduced device-read cancellation race. The original
Quadra ROM SCSI Manager consumed one extra longword per 16-byte burst when
CACR, TTRs and TC were zero. All five SCSI APIs still returned success, but
RAM contained shifted data. The CPU fix is local to
`rtl/ap68040_faster/rtl/ap68040_dmu.sv`: `E_S_ACT` now tests
`e_kill || kill_now` before preparing an operand bus operation.

This is an established CPU defect, not yet an established explanation of the
hardware OS boot failure. No synthesis, hardware build, deployment, reset or
whole-machine OS boot simulation was performed. Earlier serialized-source
fault/restart and writeback-ABI findings are separate and remain unresolved.

## Isolation

The original ROM group at `$408D1FB6..$408D1FBC` consists of four
`MOVE.L (A1),(A2)+`. The preceding instruction at `$408D1FB4` is NOP.
The backend marks it serializing and redirects from WB, discarding younger
micro-ops. `kill_now` is combinational for that cycle; DMU's `e_kill` is
registered at the end of the clocked process.

In the failing trace, at platform cycle 538507:

* WB/EX PC is `$408D1FB4`, DC2 PC `$408D1FB6`.
* The DMU is in `E_S_ACT` (state 5), with source `$50F50100`.
* `kill_now` is asserted while the old `e_kill` is still clear.
* The old `E_S_ACT` starts the read despite cancellation. Native TS follows
  at 538510; the platform completes `$6000000A` at 538524, native TA at 538525.
* That word never commits. A new native TS at 538546 consumes `$53437064`;
  committed-load trace at 538568 pairs it with PC `$408D1FB6`.
* The first completed RAM write at 538609 stores `$53437064` at `$10000`.
  The fourth RAM longword receives `$FFFFFFFF` after the burst is exhausted.

The native requests and completions both count 640, matching 640 platform
reads. The adapter is not replaying one CPU request. There are 128 empty
`$FFFFFFFF` reads. The physical SDRAM and guest byte oracle both expose the
shift; the expected first bytes are `60 00 00 0A 53 43 70 64` from the image.

With the fix the same cancellation event produces no discarded request.
The next TS is at 538532, and the first RAM write at 538595 stores
`$6000000A`. There are exactly 512 native starts, native completions and
platform reads, and no empty read. No bus timing, cache attributes,
serialization policy, TCI or instruction grouping was changed.

The recorded ROM TTR/cache-on case already passed before the fix. The
reduction additionally separates cache enable from serialization: both
reduction mappings leave CACR zero; the serialized variant installs
DTT0=`$807FC040`, DTT1=`$500FC040`. Default mapping leaves both TTRs zero.
Trace records show actual controls at every native PDMA request.

## Retained regression

```powershell
wsl env PATH=/home/elle/.local/bin:/usr/local/bin:/usr/bin:/bin python3 scripts/test_ap68040_platform.py --pdma-reduction
wsl env PATH=/home/elle/.local/bin:/usr/local/bin:/usr/bin:/bin python3 scripts/test_ap68040_platform.py --rom-scsi --no-build
```

`--pdma-reduction` uses the real IOSB/53C96, image/HPS protocol, Q800 bus and
SDRAM path. A NOP precedes four memory-to-memory longword reads, matching the
ROM shape. Controls add NOPs between the reads and select serialized versus
default mapping, always with caches disabled. Each run checks every one of
2048 bytes in the guest and physical SDRAM, guards, device completion and
exactly 512 completed bulk reads. All four paired cases pass after the fix.
Adding NOPs between reads does not cure the unfixed CPU: the initial NOP
still exposes the race. Thus consecutive MOVE issue is not the root cause.

The checked-in consecutive and separated default-mapping cases were also
built/run against an isolated scratch copy of the CPU with just the
`kill_now` condition reverted. Both fail with the original 640-read pattern.
The active checkout and fixed simulator were preserved. Before/after guest
binaries for both retained reduction cases are byte-identical (verified
independently), so the result does not depend on changing guest instructions. Before binaries,
logs, traces and copied RTL live in
`scratch/ap68040_native_platform/pdma_failing_before/`; the reproduction
helper is `scratch/ap68040_native_platform/check_pdma_before.py`.

The earlier instrumented original-ROM failure, controls and assembly inputs
are preserved under
`scratch/ap68040_native_platform/rom_scsi_speculation_before/`.
The preceding chat's initial pair also remains in `rom_scsi_first_difference/`.
`scratch/ap68040_native_platform/pdma_before_after_evidence.json` summarizes
native/platform counts and first writes from before and after captures.

Tracing is enabled by `+operand_trace`: `N TS` includes PC/CACR/TTR/TC,
`N TA` the delivered word, `K` the current WB/DC2/DMU cancellation state,
`L` the committed load, and `P` completed PDMA and first destination writes.
The original `B`, `H`, `R`, `M` evidence formats remain available. Native and
committed-load records are faster-only observations; the platform byte oracle
is identical across CPUs.

## Validation and limits

Eight original-ROM pairs / 16 executions pass after the fix:

* CD LBA16, 2048 bytes, and raw disk LBA64, 512 bytes;
* original SCSIRBlind selector 8 at CD LBA17, 2048 bytes;
* original SCSIRead at CD LBA17, three blocks / 6144 bytes, destination
  `$11FFB`, crossing the 8 KiB address and CD/block-cache boundaries;
* each in default cache-off state and recorded ROM TTR/cache-on state.

Every API returns zero, status/message are GOOD/COMMAND COMPLETE, SP is
restored, guards remain intact, and independent image/physical RAM bytes
match. Aligned cases also require exactly one bulk read per four bytes.
These tests use the original ROM dispatcher and transfer routines, without
patching their instructions. Reports record program/ROM/image/snapshot hashes.

Two additional original-ROM pairs pass with HPS responses delayed 16,000
clocks: the odd three-block read, cache-off and recorded ROM cache state.
Their reports are in `scratch/ap68040_native_platform/rom_scsi_slow/`; reproduce
with `--rom-scsi --no-build --case cd_odd_boundary_uncached --rom-host-delay 16000`
(and the corresponding `cd_odd_boundary_rom_cache` case).

The focused pointer-chain, `t_fpexc`, `t_fpu` and `t_stld` platform tests pass
after the change. The nested distinct-root fault/RTE copyback pair also passes
with both CPUs, including both frames, roots, stack and data checks. Each completed execution reports zero SDRAM protocol errors.
The reduction report is `pdma_reduction_results.json`; the expanded original
ROM report is `rom_scsi_results.json`, under the same scratch directory.

Five additional faster original-ROM runs vary ROM jitter seeds, base latency
(0, 2, 6 and 15 clocks) and retained-ROM-line enable. All pass with exactly
512 native starts and platform bulk reads. Timing reports and traces are in
`scratch/ap68040_native_platform/rom_scsi_timing/`; the helper is
`scratch/ap68040_native_platform/check_rom_scsi_timing.py`. The fixture accepts
`+rom_seed=HEX` and `+rom_latency=DECIMAL`; default timing is unchanged.

The bounds remain three million platform clocks per execution. These are
actual ROM/device operations in a compact fixture, not an OS boot. Recorded
serialized mappings can mask the demonstrated race, so this finding alone
cannot identify the universal boot cause or prove that hardware now boots.
