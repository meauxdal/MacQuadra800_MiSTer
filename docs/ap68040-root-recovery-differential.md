# Distinct-root recovery differential, 2026-10-18

The next bounded real-platform experiment found **no additional previous/faster
CPU difference**: 21 pairs / 42 executions pass independent root, stack, frame,
register and data checks. All active frame fields and result records match.
Every execution reports zero SDRAM protocol errors.
Runs take 5,349 through 21,538 platform clocks, below the 3,000,000-clock cap.

This narrows the tested user/supervisor recovery gap. It does not establish OS
boot compatibility, resolve the previously exposed writeback ABI/serialized
FIFO failures, or identify the universal boot cause. No CPU functional RTL
change or hardware build was made.

## Reproduce

```powershell
wsl env PATH=/home/elle/.local/bin:/usr/local/bin:/usr/bin:/bin python3 scripts/test_ap68040_platform.py --root-recovery
```

Use `--no-build` with the existing platform executables, `--cpu faster` or
`--cpu legacy` for one side, and `--case user_nested_read_invalid_copyback`
for one case. The executed matrix used `--no-build --collect-differences`;
only guest assembly and the Python runner changed, so the existing simulator
executables support it without recompiling RTL. Each execution retains the
fixture's 3,000,000-clock timeout and normal ROM reset/overlay path.

Guest source: `scripts/fixtures/ap68040_faster/mmu_root_recovery.s`.
Results: `scratch/ap68040_native_platform/root_recovery_results.json`, plus
`root_recovery_*.bin`, assembly logs, per-CPU logs and raw memory traces.
The JSON records the assembled binary SHA256 shared by each pair, all raw
60-byte frames, final observations and independent check failures. A selected
case writes its own report without replacing the full matrix report.

## Why this experiment

The saved pre-boot ROM state uses distinct roots, whereas the previous
`mmu_recovery.s` matrix assigned URP and SRP to the same synthetic table.
Upstream `t_mmu.s` already contains user A7 rollback and MOVES root-selection
tests; their passing isolated-core runs were not repeated as new evidence.
This experiment combines distinct physical mappings, mapping repair and RTE
on the actual Q800 service/SDRAM path, preserving complete frames for direct
comparison. It also adds a nested access error at the same logical address
through the other root.

The ordinary user-mode transition and TRAP return follow upstream
`t_mmu.s`'s `user_code`, `u7done` and `h_utrap` shapes. It uses FC1 user data,
FC2 user instructions and FC5 supervisor data only. It does not depend on the
manual/reference disagreement recorded there for MOVES FC0/4.

## Matrix and independent oracle

Each case runs with caches disabled, instruction caching enabled, and
instruction caching plus copyback data/stack mappings:

| Case | Fault and recovery |
| --- | --- |
| `user_read_invalid` | User longword read/postincrement; repair invalid URP data page |
| `user_write_invalid` | User register store/postincrement; repair invalid URP data page |
| `user_a7_write_invalid` | User `MOVE.L (A7)+,(A1)+`; repair destination, preserve ISP, advance USP once |
| `moves_read_user_invalid` | Supervisor MOVES with SFC=1; fault and repair user data mapping |
| `moves_write_user_protected` | Supervisor MOVES with DFC=1; remove user page write protection |
| `user_ifetch_invalid` | User JSR through invalid URP instruction page; repair, execute target, RTS |
| `user_nested_read_invalid` | Outer user data fault; handler faults at same logical address through SRP; repair both and RTE twice |

SRP=`$4000`, URP=`$5000`, with separate pointer/page tables and 8 KiB pages.
Logical `$10000` maps to physical `$10000` under SRP (decoy `$55667788`),
and physical `$18000` under URP (initial `$11223344`). Supervisor translation
of the decoy is primed before entering user/MOVES cases, except when that
page is intentionally invalid for the nested case. Final checks verify the
user value/store, intact decoy and each repaired physical mapping.
Data observations use CPU loads through supervisor identity aliases after
CPUSHA; the fixture captures the serialized result log directly from SDRAM.
This does not add a separate raw destination-RAM dump like the SCSI suite.

USP starts at logical `$D000`, mapping to physical `$1D000`; ISP starts at
resident supervisor `$E000`. The A7 source is positive `$40DE1234` so ordinary
MOVE stores have equal incoming/result CCR. This deliberately avoids
reclassifying the already-known stacked-CCR difference. MOVES preserves
incoming SR `$2704`. The runner checks outer saved SR, final SR, SFC/DFC,
trap count, preserved registers, postincrements and final USP/ISP.

Outer format-7 frames start at ISP `$DFC4`. In the nested case, the handler's
28-byte register save remains on the stack and the inner frame starts at
`$DF6C`. Both frames have FA `$10000`, with outer SSW `$0501` (user data
read) and inner `$0505` (supervisor data read). The outer stacked PC names
the user operation; the inner names the handler's read. The inner read must
deliver the supervisor decoy, then the resumed user operation must deliver
the distinct user value. Both stack pointers return to their expected state.

Other checked SSWs are `$0401` for user-space destination writes and `$0502`
for the user instruction-fetch fault. Registers, result records and active
frame fields are compared directly. Only invalid writeback payloads are
masked, using the same field-level policy as the prior recovery matrix;
the original bytes remain in JSON. All generated slots remain V-clear.

Negative control: in a separate scratch source, changing the user repair
from PA `$18000` to PA `$10000` still reaches guest completion. The runner
rejects D4=`$55667788` instead of `$11223344` and the incorrect repaired
physical mapping. The saved rejection is under
`scratch/ap68040_native_platform/negative_root_repair/`; scratch helper
`check_root_negative.py` records the exact source mutation. Standard matrix
reports and source are untouched by that control.

## Remaining limits and next evidence

These are compact synthetic mappings, not a replay of the full saved ROM/OS
state. The access-error handler repairs only the selected descriptors,
flushes ATCs and returns with the original frame. It explicitly rejects
advertised valid writebacks. The user-mode TRAP epilogue changes its own
ordinary trap frame to return to supervisor mode; no access-error PC or
writeback valid bit is manufactured to make recovery pass.

The suite covers current whole-instruction restart paths with resident,
serialized handler logs/tables/ISP. In the icache cases the handler shares
the cacheable code page. It does not validate valid WB1/2/3 completion,
physical FPGA RAM primitives, asynchronous interrupts or bus errors during
frame stacking, the actual OS handler, or side-effecting I/O sources.
Copyback observations are taken after a data-cache push. No complete OS
simulation, synthesis, deployment, hardware reset or external contact ran.

The demonstrated serialized FIFO double consumption and silicon writeback
ABI mismatch remain specific recovery contract failures, but their
occurrence during the failing boots is still unproven. A coordinated
write-fault completion implementation must account for saved PC, committed
registers/CCR, pending writebacks and continuation, retaining FIFO/RMW
regressions. This experiment supplies no basis for setting WB.V alone or
requesting another speculative hardware build.
