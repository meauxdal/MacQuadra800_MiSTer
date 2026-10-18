# CPU-driven SCSI differential, 2026-10-18

The bounded READ(10) comparison matches between this repository's previous
CPU integration and its imported faster integration. This establishes the
covered transfer contracts below; it does not establish OS boot compatibility
or exclude other SCSI sequences, interrupt workloads, or fault recovery.

## Reproduce

From this checkout in PowerShell:

```powershell
wsl env PATH=/home/elle/.local/bin:/usr/local/bin:/usr/bin:/bin python3 scripts/test_ap68040_platform.py --scsi
```

After building, `--no-build` repeats execution; `--case cd_mmu_alias` selects
one case. `--cpu legacy` or `--cpu faster` runs one side for diagnosis.
The default image is `scratch/ap68040_os81_cd/installer.iso`, verified SHA1
`7900544de9a3653494262e9b8b1448295d66239d`. Override with `--image PATH`.
The report records the actual image digest and assembled program SHA256.

Outputs are under `scratch/ap68040_native_platform/`: `scsi_results.json`,
per-case/per-CPU `.log` and `.trace` files, program binaries and build logs.
The comparison stops at the first differing normalized transaction or RAM
byte, or immediately on a failed guest/platform check or cycle timeout.

## Actual paths and oracle

Both builds use the same platform fixture, normal ROM reset/overlay removal,
RAM-resident guest binary, ISO bytes, Q800 IOSB/53C96, SCSI block cache,
SDRAM bridge/controller and protocol-checked SDRAM chip model. The prior CPU
uses `rtl/wombat_cpu.sv`, `rtl/ap68040/rtl/`, and `Q800_LEGACY_CPU=1`; the
faster CPU uses its existing wrapper, native adapter and vendored faster core.
No substitute device register or direct injection into the destination RAM
is used. CPU RAMs use their portable simulation implementation.

The program follows `verilator/tb_ncr53c96.sv:rom_command`, `read_regs` and
its T2 burst sequence: TC=1, empty-FIFO DMA select `$C1`, CDB FIFO writes and
trailing PDMA byte; data in 16-byte `$90` bursts gated by TC0/FIFO readiness.
It checks selection BS|FC/step 4, per-burst BS, final STATUS phase, ICCS FC,
GOOD status, COMMAND COMPLETE message and disconnect. This is the existing
bench's ROM-derived dialect; its referenced standalone ROM-driver document
is absent from this checkout. It does not cover the Unix driver dialect.

IOSB supplies the real byte/word PDMA port `$50F10100` and the mirrored
longword port `$50F50100`. The read-only host uses ordinary image offsets in
512-byte HPS blocks and calls the existing `verilator/sim/cd_window.cpp`
and `sim/mac/mac_cdrom_{resp,play}.cpp` builders for CD windows. It includes
the normal startup reset-command/capability-probe windows. Ack leads word
zero, stays high through the requested blocks, then falls, following the
existing SCSI bench and `sim_blkdevice.cpp` protocol. CD command windows are
accepted in memory; the image file is never written.

Every guest byte is compared against independently appended ISO data through
CPU loads, with four-byte destination guards. After a cache push and disabling
the cache for the completion mailbox, the fixture checks every physical
SDRAM destination byte. The Python runner additionally compares the RAM trace
against direct ISO slices. One deliberately corrupted expected byte was
rejected by the guest (`negative_expected.log`), confirming the success path
depends on the oracle. All passing runs have zero SDRAM protocol errors.

Raw traces retain completed I/O address, width, direction and data, HPS
requests/command-window words and ack transitions, and all destination RAM
bytes. Normalization retains the last sampled status/FIFO value before each
non-poll transaction while dropping timing-dependent polling repetitions and
intermediate not-ready values. CPU transaction order and HPS transaction order
are compared separately: their clock timing and interleaving can differ.
Host delays are identical request-relative clock counts, rather than fixed
absolute simulation timestamps. Each guest execution is capped at 3,000,000
platform clocks.

## Corrected MMU provenance

The handoff mistakenly identified `$50F06000` as the SCSI page. RTL decodes
SCSI registers at `$50F10000`; the saved snapshot confirms these actual pages:

| Saved root | Logical address | Page descriptor | Cache mode |
| --- | --- | --- | --- |
| `$03FFFA00`, `$03FEEA00` | `$50F10000` | `$50F10059` | CM=2, serialized/cache inhibited |
| `$03FFFA00`, `$03FEEA00` | `$50F50100` | `$50F50079` | CM=3, nonserialized/cache inhibited |
| `$03FEEA00` | `$00F10000` | `$50F10059` | same register/base DMA mapping |
| `$03FEEA00` | `$00F50100` | `$50F50079` | same mirrored bulk mapping |

The runner verifies all six descriptors if the saved snapshot is present.
The MMU cases use compact synthetic 8 KiB tables reproducing these attributes
and aliases, plus copyback RAM pages (`$39` attributes), with instruction and
data caches enabled. They do not restore the entire saved machine state or
its distinct roots. The ROM-cache cases use the recorded DTT0=`$807FC040`,
DTT1=`$500FC040`, MMU disabled, and both caches enabled.

## Covered matrix

| Case | Target and read | Destination | Transfer widths | HPS delay | State |
| --- | --- | --- | --- | ---: | --- |
| `cd_control` | CD ID 3, LBA 16, one 2048-byte block | `$10000` | long | 40 | caches/MMU off |
| `disk_control` | disk ID 0, LBA 64, one 512-byte block | `$10000` | long | 40 | caches/MMU off |
| `cd_rom_cache` | CD LBA 16, one block | `$10000` | long | 40 | ROM TTRs/caches |
| `cd_rom_mixed_odd` | CD LBA 16, one block | `$10001` | byte/word/long | 40 | ROM TTRs/caches |
| `cd_mmu` | CD LBA 16, one block | `$10000` | long | 40 | MMU/copyback RAM |
| `cd_mmu_alias` | CD LBA 16, one block | `$10003` | byte/word/long | 40 | MMU/low I/O alias |
| `cd_mmu_boundary_slow` | CD LBA 17, three blocks | `$11FFB` | byte/word/long | 16000 | MMU/page crossing |
| `disk_mmu_boundary_slow` | disk LBA 7, three blocks | `$11FFD` | byte/word/long | 16000 | MMU/page + block-cache group crossing |

The disk target uses raw bytes from the same known ISO, not a separate
bootable HDD image. The eight paired cases cover 18,432 destination bytes per
CPU. Transfers include cache-line, 512-byte sector, 2048-byte CD block and
8 KiB page boundaries, with odd destination longword stores. The slow host
cases exercise inter-block waiting. All eight pairs match.

The original pointer-chain, `t_fpexc`, `t_fpu` and `t_stld` platform programs
also retain their previous passing cycle counts and zero SDRAM errors after
the fixture extension.

## Remaining investigation

There is no SCSI discrepancy here to justify another hardware overlay or
build. The next discriminating work belongs to the MMU/exception-recovery
contract: reproduce software-visible recovery and writeback handling against
both CPU integrations, using the same short real-platform path. The existing
serialized-source/destination-fault example remains a coverage gap, not an
observed OS boot cause. This comparison covers successful supervisor reads;
it does not cover destination faults, OS fault handlers, user-space mappings,
interrupt-driven SCSI, write commands, complete boot drivers, SONIC contention,
physical FPGA RAM primitives, or fitted timing.
