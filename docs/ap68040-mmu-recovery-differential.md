# MMU and exception recovery differential, 2026-10-18

The short real-platform comparison now exposes two distinct results:

* A previous/faster CPU difference in **stacked CCR on a destination write
  fault**. The faster CPU preserves the incoming flags; the previous CPU
  stacks the flags computed by the faulting operation. Both finish these
  RAM operations correctly after mapping repair and RTE.
* A **shared serialized-source recovery failure**, reproduced through the
  actual IOSB/53C96 FIFO. A destination page fault causes both CPUs to consume
  the FIFO twice. Existing silicon captures also establish a writeback ABI
  difference that the old corpus scorer excluded.

Neither result establishes the cause of the reported OS boot failures.
No CPU functional change, hardware build or capture is part of this work.

## Commands and outputs

```powershell
# Default: build both CPUs, stop at the first active difference (exit 1).
wsl env PATH=/home/elle/.local/bin:/usr/local/bin:/usr/bin:/bin python3 scripts/test_ap68040_platform.py --recovery

# Complete the bounded matrix, retaining differences and returning exit 1.
wsl env PATH=/home/elle/.local/bin:/usr/local/bin:/usr/bin:/bin python3 scripts/test_ap68040_platform.py --recovery --no-build --collect-differences

# Reduced register-store difference; no SCSI read or postincrement involved.
wsl env PATH=/home/elle/.local/bin:/usr/local/bin:/usr/bin:/bin python3 scripts/test_ap68040_platform.py --recovery --no-build --case reg_write_nonzero

# Shared device-source contract failure, even when running only one CPU.
wsl env PATH=/home/elle/.local/bin:/usr/local/bin:/usr/bin:/bin python3 scripts/test_ap68040_platform.py --recovery --no-build --cpu faster --case fifo_dest_fault

# Decode previously captured silicon/RTL frames; no simulation or hardware.
wsl python3 scripts/audit_ap68040_mmu_frames.py
```

Outputs live in `scratch/ap68040_native_platform/`: `recovery_results.json`,
case-specific result JSON when `--case` is used, `recovery_*.log`, `.trace`,
`.bin`, and `archived_mmu_frame_audit.json`. The JSON records identical-program
SHA256, full 60-byte frames, handler-entry and final register/data snapshots,
completed FIFO accesses, comparison results and independent contract failures.

## Scope and independent checks

`scripts/fixtures/ap68040_faster/mmu_recovery.s` runs through the same normal
ROM trampoline, real Q800 service, SDRAM bridge/controller and checked chip
model as the SCSI differential. It induces faults using actual MMU page
descriptors; the fixture does not inject faults or override CPU state.

Twelve cases run in each of three configurations: caches off with serialized
RAM; instruction cache active on the code page; instruction caching plus
copyback source/destination RAM. The 8 KiB tables keep the handler, result
log, tables and stack resident and serialized. The SCSI FIFO page is always
`$50F10059` (serialized/cache inhibited).

| Case | Tested operation |
| --- | --- |
| `read_invalid` | longword read/postincrement from an invalid page |
| `write_invalid` | RAM-to-RAM copy with source/destination postincrement, invalid destination |
| `write_protected` | same copy into a write-protected page |
| `split_read` | odd word read across an 8 KiB boundary, second page invalid |
| `split_write` | odd longword copy crossing an 8 KiB boundary, second page invalid |
| `fifo_control` | real FIFO byte to resident RAM, no fault |
| `fifo_dest_fault` | same FIFO read, invalid destination page |
| `rmw_protected` | `ADD.L` into a write-protected page; detects duplicate application |
| `ifetch_invalid` | JSR into an invalid instruction page; repair and RTS |
| `reg_write_nonzero` | register-to-memory store, incoming Z=1, nonzero source |
| `reg_write_zero` | register-to-memory store, incoming Z=0, zero source |
| `observed_odd_word` | word read at `$FFFFB1DF`; validates SSW `$0545` |

The handler records the original frame, repairs one descriptor, flushes ATCs,
checks writeback slots in order 1/2/3, and executes RTE. Its completion routine
supports ordinary longword writebacks and explicitly rejects other valid
shapes. **All current CPU-generated slots are invalid**, so this suite does
not claim positive coverage of valid-writeback completion. No V bit or saved
PC is manufactured to make the CPUs pass.

The runner independently checks fault count, format/vector/ATC bit, restart
PC, register preservation/postincrements, final CCR, split-store data and
exactly-once RMW result. It compares active frame fields and result/device
sequences across CPUs. Inactive writeback payloads alone are masked when
their V bit is clear; their raw bytes remain recorded. This is narrower than
the old scorer's exclusion of entire frame windows.

All **72 executions** complete with zero SDRAM protocol errors. Fifteen pairs
match; 21 differ only at frame byte offset `$01`, the low SR/CCR byte. All
post-recovery registers and RAM results match across CPUs. The six FIFO fault
executions additionally fail the independent single-consumption contract.
These are intentional nonzero test results, not a passing recovery suite.

## Reduced previous/faster difference

With A1 pointing at an invalid destination page:

```asm
    move.l #$12345678,d4
    move.w #$2704,sr
    move.l d4,(a1)
```

The previous CPU stacks SR `$2700`; faster stacks `$2704`. Reversing the
condition (`D4=0`, incoming SR `$2700`) gives previous `$2704` and faster
`$2700`. This rules out FIFO behavior, source reads and postincrement as
requirements for the difference. Both frames have SSW `$0405`, invalid WB3,
the same faulting PC, and the same diagnostic write data. After repair/RTE,
the store and final CCR are correct on both cores.

This is an exposed handler-visible difference, **not an adjudicated faster
CPU bug**. The archived silicon rows below have matching incoming/result
flags and do not resolve which flags this particular restart model should
stack. Changing CCR alone would also leave the larger writeback/PC contract
unresolved.

## Serialized FIFO source: real platform failure

The guest flushes the actual NCR FIFO, writes bytes `$11,$22,$33,$44`, and
performs `MOVE.B (A0),(A1)+` from `$50F10020` into an invalid RAM page.

| Observation | No-fault control | Destination-fault case, both CPUs |
| --- | --- | --- |
| First byte committed to RAM | `$11` | **`$22`** |
| Next two FIFO reads | `$22,$33` | `$33,$44` |
| Total completed FIFO reads | 3 | **4** |
| Fault count | 0 | 1 |
| Faulting byte retained in diagnostic WB3D | n/a | `$11` |
| WB1/WB2/WB3 valid bits | n/a | all clear |

The faulting instruction is restarted and rereads the source. The mapping
repair and destination pointer recovery work; the original consumed byte is
lost. This extends the older synthetic-register example to a real side-effecting
device register and proves the behavior also exists on the prior integration.

The [M68040 user's manual](https://www.nxp.com/docs/en/reference-manual/MC68040UM.pdf),
sections 7.7 and 8.4.6, describes serialized-read protection against repeated
reads and software completion of pending writebacks after mapping repair.
It does not justify completing an advertised writeback and then reexecuting
the same store. Fixing this requires coordinated saved PC, committed
registers/CCR, valid writeback contents and continuation/restart behavior.
Simply setting WB3.V would risk duplicate stores or RMW updates.

## Existing silicon evidence: the old scorer missed a real ABI difference

`scripts/audit_ap68040_mmu_frames.py` decodes the original frame windows in:

* `SingleStepTests/results/mmu/hardware_full_quadra800_2026-08-28.jsonl`
* `SingleStepTests/results/ap68040/verilator_mmu_2026-08-28.jsonl`

The two store rows use `MOVE.L D1,$9010` with source `$55555555` or `$66666666`.

| Field | Quadra silicon | Archived AP68040 |
| --- | --- | --- |
| SSW | `$0485` | `$0405` |
| WB2S | **`$0085`, valid** | `$0000` |
| WB2A / WB2D | `$9010` / original store value | zero / zero |
| WB3S | `$0085`, another valid pending writeback | `$0000` |
| Diagnostic WB3D | `$00008000` (different pending writeback) | original store value |

The audit preserves all raw fields and PCs without claiming that relocated
PCs are directly comparable. The hardware recovery stubs disable translation
and abandon the frame, rather than repairing it and executing RTE. Thus these
captures establish frame contents, not successful OS-style continuation.

`SingleStepTests/gen/score_vs_oracle.py` classifies differences in the whole
`$3FF00..$3FFFF` frame region as `frame`, so its previous passing result did
not validate this ABI. This does not invalidate the other passing instruction
and MMU records. It does establish that “both cores restart with V clear” is
not sufficient evidence of compatibility with the captured silicon contract.

## Hardware symptom and remaining limits

The `$FFFFB1DF` case deliberately maps the high logical page to resident RAM
after its first ATC fault. Both CPUs produce FA `$FFFFB1DF`, SSW `$0545`, then
return the correct word and preserve registers in all cache configurations.
It reproduces the observed access shape, not the provenance of that pointer,
the actual failing instruction at `$FC4E`, or the OS handler's mapping policy.

The existing SCSI MMU/alias case still matches after extending the fixture.
The actionable next architectural work is a coherent write-fault completion
contract, with the preserved FIFO/RMW regressions and the raw silicon frame
evidence as constraints. Nested faults, MOVEM continuation, valid WB1/WB2/WB3
completion, user/supervisor root switching and the actual OS exception handler
remain outside this bounded matrix. There is still no demonstrated boot fix
or reason to request another speculative hardware cycle.

## Subsequent distinct-root experiment

The next short platform experiment now covers distinct user/supervisor roots,
user A7 rollback, MOVES FC1 fault recovery, user instruction-fetch repair and
a nested supervisor fault inside a user-fault handler. All 21 pairs / 42
executions pass independent checks and match across CPUs, with zero SDRAM
protocol errors. This narrows those previously listed coverage gaps without
resolving valid-writeback completion or establishing a boot cause. See
[commands, physical oracles and exact limits](ap68040-root-recovery-differential.md).
