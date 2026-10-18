# Action handoff: continue until an actual OS can boot

> Update from the continuation: the reproduced ROM SCSI failure has been
> isolated and fixed locally. `E_S_ACT` missed same-cycle `kill_now` from
> the preceding serializing NOP and consumed a discarded device read.
> Read [the cause, fix, before/after evidence and regressions](ap68040-pdma-cancellation.md)
> before following the older immediate-task instructions below. The original
> and reduced failures are preserved; original-ROM and reduced transfer checks
> now pass. Hardware OS boot remains unverified.

## User objective and working rules

All actual OS boots fail with the faster integration. The user said:
"carry on then, we are completely unable to proceed until we can boot
something on the core. any tests are acceptable, really. i just feel we
have overlooked something because the CPU passes all tests". They then
requested a handoff because this chat was over half its context.

Keep investigating and running discriminating experiments; do not return
another plan or treat passing narrow tests as completion. No boot cause or
justified boot fix has been established. The prior frame audit already shows
why the passing corpus does not prove every CPU contract: valid writebacks
were excluded by its scorer, and the serialized FIFO restart loses a byte on
both CPUs. Those failures have not been observed during the failing OS boots.

Use the same checkout and preserve all work. The user commits concurrently:
HEAD advanced from `3372b2f` to `9432506` (`ss4`) during this chat. Recheck
status rather than relying on an earlier uncommitted-file list. No AGENTS.md
applies in the workspace or its searched ancestors. Do not import or reset
either CPU tree. No subagents, contacting others, synthesis/Quartus/fitting,
deployment, hardware resets or speculative hardware build cycles. Earlier
instructions also prohibit long whole-machine OS simulations; the broad
permission for tests was used for bounded local experiments, not to restart
the old stalled full-boot runs. No PRAM-reset/RAM-size remedy is proposed.

Read these earlier local handoffs for established evidence and constraints:

* `docs/ap68040-scsi-differential-handoff.md`
* `docs/ap68040-scsi-differential-results.md`
* `docs/ap68040-mmu-recovery-differential.md`
* `docs/ap68040-root-recovery-differential.md`

## Completed this chat: real timers and original ROM routines

All results live under `scratch/ap68040_native_platform/`.

### Actual VIA interrupts

```powershell
wsl env PATH=/home/elle/.local/bin:/usr/local/bin:/usr/bin:/bin python3 scripts/test_ap68040_platform.py --interrupts --no-build
```

`via_interrupts.s` programs the real VIA1 T1 and T2 one-shot timers through
IOSB and handles actual IPL1/autovector 25. No bench IRQ injection. It tests
interrupts amid odd-address RMWs, STOP wakeup and masked-pending -> STOP,
with caches off, recorded ROM TTRs/caches, and compact MMU/low I/O alias plus
copyback data. Each execution handles 32 interrupts while checking all D0-D7
and A0-A6, the frame vector/SR, timer IFR acknowledgement, final stack and
RMW result. 18 paired cases / 36 executions / 1,152 interrupts passed.
91,549..207,726 clocks per run; zero SDRAM protocol errors.
`interrupt_results.json` preserves results; instruction timing/unused IFR
flags legitimately differ, so MATCH here means both satisfy the checked
contract rather than identical raw device transcripts.

### Original ROM BlockMove, MOVE16 and A-line trap dispatch

```powershell
wsl env PATH=/home/elle/.local/bin:/usr/local/bin:/usr/bin:/bin python3 scripts/test_ap68040_platform.py --rom-copy --no-build
wsl env PATH=/home/elle/.local/bin:/usr/local/bin:/usr/bin:/bin python3 scripts/test_ap68040_platform.py --rom-copy --trap-calls --no-build
```

The fixture can now load the actual 1 MiB `releases/boot0.rom` and supply
the platform's retained-ROM-line sideband, previously tied off. `+rom_lines`
and `+rom_jitter` provide whole-line retention and deterministic 6..37-clock
request-relative ROM latency. This models the platform-side line contract,
not the physical DDR3 PHY/two-beat host bridge. Normal ROM reset/overlay
removal is retained through a guest trampoline: only ROM reset vectors and
six bytes at `$FF000` are patched. Called ROM routines stay unmodified.

`rom_blockmove.s` calls actual ROM `$4080CA10` and accelerated `$40884400`.
The saved RAM's OS trap `$2E` table entry at `$4B8` points to `$4080CA10`;
cache-flush callback `$6F4` points to `$40885030` (NOP/CPUSHA BC/RTS),
CPUFlag `$12F` is 4 and address mask `$31A` is `$00FFFFFF`.
The accelerated routine uses its real `$408870AA` cache-maintenance helper.
Trap cases additionally invoke actual A-line vector `$408099B0` via `$A02E`
with code relocated to `$2000` to keep the low-memory trap table intact.

Direct matrix: 8 copy shapes x 2 routines x 3 cache states = 48 paired
cases / 96 executions. Shapes cover 7-byte bitfield copy, odd alignment,
513-byte copies, both overlap directions, source/destination 8 KiB crossings
and 4 KiB copy. States are caches off, write-through and copyback, with
instruction caching active in the latter two. Source/destination lines are
made dirty before entry. Trap matrix: 3 shapes (small, odd, large) x 2
routines x 3 states = 18 pairs / 36 executions. All pass, including complete
16 KiB arena equality, unchanged guards/source bytes, return D0, SP, D3-D7
and comparison of returned A0/A1. 209,850..556,768 clocks; zero SDRAM errors.
Reports: `rom_copy_results.json`, `rom_trap_copy_results.json`.

The initial repeating input pattern weakened aligned-copy checks. That run
was stopped; final COMPLETE reports use deterministic nonrepeating
`SHAKE256("Q800 ROM BlockMove independent arena v1")` data and explicitly
reject an oracle where omitting the copy would leave the expected arena
unchanged. A separate negative control substitutes ROM RTS `$40885034` for
the call target; guest checking rejects it at first destination byte
`$12005`. `negative_rom_omission/` and scratch `check_rom_negative.py` hold
that result. Vasm `-D` numeric CLI values must be decimal; `0x...` silently
warned about trailing garbage and defined zero in an early negative-control
attempt. All real runner constants use decimal f-string values.

The actual hardware fault PC `$FC4E` is table data in the older saved
snapshot, so it cannot be decoded there as the hardware's faulting instruction.
The old disassembler prints ROM-base addresses even for a RAM input; do not
mistake its `$4080FC4E` label for a proven ROM execution address.

## Current experiment: original ROM SCSI Manager

The earlier successful READ(10) fixture used hand-written ROM-dialect code.
The next experiment executes the original ROM manager and real `$A815`
trap path, aiming to expose code/ABI/integration interactions that manual
register traffic cannot cover. Source: `rom_scsi_read10.s`; runner:
`--rom-scsi`. This is a bounded polled READ(10), not an OS boot.

The saved toolbox trap entry `$E54` points to `$40807460`. The dispatcher
loads A4 from lowmem `$C0C` (`$76B0`) and the active NCR-specific selector
table there points to ROM `$408D16xx..$408D19xx`, rather than the older
5380 routines linearly following the generic dispatcher. The runner copies
saved RAM `$100..$1FFF` (globals/trap tables) and `$7000..$7FFF` (resident
SCSI manager tables/queues) into the guest input; it does not restore CPU,
MMU or peripheral state. Guest code starts at `$2000`, log at `$3200`.
It uses actual A-line dispatch, SCSIGet=1, SCSISelect=2, SCSICmd=3,
SCSIRead=5, SCSIComplete=4, with a scInc/scStop TIB. Every API result,
GOOD status, COMMAND COMPLETE message, stack restoration and destination
guards/data are checked. The fixture independently checks physical SDRAM
bytes against direct ISO data. Its normal image/HPS host handles startup
capability windows; no image writes occur.

Known NCR selectors for the next extension: Read=5 (`D4=$20`), Write=6
(`$24`), RBlind=8 (`$28`), WBlind=9 (`$2C`), SelectATN=11. TIB opcodes in
the actual ROM dispatch: scInc=1, scNoInc=2, scAdd=3, scMove=4, scLoop=5,
scNop=6, scStop=7, scComp=8. Verify parameters/semantics against the decoded
routine before extending, rather than assuming the old manual-driver path.

The first legacy CD control reached all guest checks, actual status/message
completion and fixture's physical SDRAM check. Python then rejected missing
RAM trace records: the newly combined `+recovery`/`+image` mode closed the
trace after M records before emitting R bytes. This was a fixture bug,
not a SCSI/CPU failure. The fixture now shares one open trace and closes it
after both captures; duplicate I/O tracing is disabled in the recovery arm
when SCSI mode is active. The control was rebuilt/rerun after that fix.

### New reproducible previous/faster difference — START HERE

After fixing trace finalization, the paired `cd_uncached` control was run
twice, once with added failure diagnostics. **Legacy passes, faster fails.**
This is the first actual-ROM SCSI driver failure in these platform tests.
No functional CPU/integration fix has been applied. Do not call it the OS
boot cause yet, and do not assume it is an adapter or CPU defect before
reducing/locating the extra accesses.

Both CPUs complete all five API calls with zero result, GOOD status and
zero COMMAND COMPLETE message, and restore SP=`$E000`. The faster guest
then fails the first destination byte comparison. Failure mailbox:

| Address | Meaning | Faster value |
| --- | --- | --- |
| `$3200` | successful API count | 5 |
| `$3204..$3211` | API results, status, message | all zero |
| `$3214` | final SP | `$E000` |
| `$3218` (word) | SR on failed compare | `$2709` |
| `$321C` | D0 / actual data byte | `$00000053` |
| `$3220` | A0 after failed byte load | `$00010001` |
| `$3224` | expected-data A1 after comparison | `$00008001` |
| `$3228` | D7 before first DBRA | `$000007FF` |

Actual source bytes at ISO offset `$8000` are
`60 00 00 0A 53 43 70 64 60 00 00 12 48 E7 7F FC`.
Thus first destination byte is **`$53` rather than `$60`**. This image
location is Apple driver data (`SCpd`), not an ISO9660 descriptor assumed
from generic ISO layout; direct image bytes are the oracle.

Completed longword reads from physical bulk port `$50F50100`:

* Legacy: **512** reads, no `$FFFFFFFF` values.
* Faster: **640** reads, **128** values `$FFFFFFFF`.
* First faster words:
  `$6000000A, $53437064, $60000012, $48E77FFC, $FFFFFFFF,
  $20057A00, $1A00E145, $70006006, $48E77FFC, $FFFFFFFF, ...`.
* Legacy contains the same first four good words, then continues directly
  with `$20057A00` (no extra read). The pattern appears as an extra read
  after each 16-byte burst. Derive the precise ordering rather than assuming
  the printed extra value alone explains how the first RAM word was replaced.

SCB callback at `$76B0+$19C=$784C` is `$408D1E9E`. It dispatches through
SCB `$A4+D4` to the data routine. Original ROM `$408D1FB6..$408D1FBC`
contains **four consecutive `MOVE.L (A1),(A2)+`** instructions, with NOPs
outside the group. A1 points at mirrored bulk PDMA `$50F50100`; A2 advances
through the RAM destination. This real instruction grouping was absent
from the manual SCSI transfer guest and is the immediate reduction lead.
The callback temporarily installs its own access-error vector at lowmem 8;
retain that behavior as a possible interaction until ruled out.

Reproduce now (both binaries were rebuilt successfully after fixture changes):

```powershell
wsl env PATH=/home/elle/.local/bin:/usr/local/bin:/usr/bin:/bin python3 scripts/test_ap68040_platform.py --rom-scsi --no-build --case cd_uncached
```

It exits nonzero after legacy PASS and faster guest failure. Current logs,
raw I/O/HPS traces, binary and `rom_scsi_results_cd_uncached.json` preserve
the added diagnostics. The original failing pair before diagnostic edits
is separately copied to `scratch/ap68040_native_platform/rom_scsi_first_difference/`.
Original assembled program SHA256:
`4d5af36939091f58c8fb4b34077363f1742c6f43c2bdbe67189ec9b322a2e075`.

At handoff no simulations remain running. HEAD last observed `9432506`;
current edits include the new `--rom-scsi` runner, combined-capture fixture
fixes, guest failure diagnostics and this handoff. The user already committed
the previous timer/ROM/root experiments and the first ROM-SCSI guest into
`ss4`; do not discard or duplicate them.

## Continue with action

Default `--rom-scsi` currently has CD ID3 LBA16 / 2048 bytes and raw disk
ID0 LBA64 / 512 bytes, each cache-off and recorded ROM TTR/cache-on.
The immediate priority is reducing the new failure, not completing more
passing controls. Compare `cd_rom_cache` to establish the role of the
recorded DTT1=`$500FC040` (serialized cache-inhibited), since `cd_uncached`
starts with caches/TTRs off but actual ROM may change CPU controls. Observe
CACR/TTRs during the transfer rather than assuming they stay at reset values.
Build a bounded real-device reduction around the four consecutive
`MOVE.L (A1),(A2)+`, with a NOP-separated control and explicit serialized
versus default mapping. Record native TS/TA requests as well as completed
platform requests so CPU overissue can be distinguished from adapter replay.
Locate the first wrong RAM write and any source read discarded/reissued by
the CPU; preserve the original failing-before regression before fixing it.

When that is understood, remaining controls are available with:

```powershell
wsl env PATH=/home/elle/.local/bin:/usr/local/bin:/usr/bin:/bin python3 scripts/test_ap68040_platform.py --rom-scsi --no-build
```

Reports `rom_scsi_results.json` or `rom_scsi_results_CASE.json` retain binary,
ISO, ROM and snapshot hashes. Logs/traces use `rom_scsi_CASE_CPU` prefixes.
`--cpu legacy|faster` and `--case cd_uncached|cd_rom_cache|disk_uncached|disk_rom_cache`
select an individual run. Preserve the original known ISO and snapshot.

Only after reducing the difference, extend the actual ROM API case to RBlind, odd destinations,
multi-block/page-boundary transfers and delayed HPS, with exact physical-RAM
oracles and stop at the first discrepancy. This is a more useful immediate
next step than repeating the manual driver or isolated CPU corpus. Reduce
the first differing software-visible transaction/byte before changing
functional RTL. Maintain the universal boot objective; matched
controls still do not establish a boot cause or permit a speculative build.

Tool environment: PowerShell; local WSL runs require escalation due sandbox
access restrictions. Explicit PATH in the commands finds vasm. Put complex
cross-shell code into LF Python/shell files. `scratch/boot_disasm` takes
`binary start_hex end_hex`, prints addresses relative to `$40800000` and
reads only the first 1 MiB. No external source lookup or contact ran here.
