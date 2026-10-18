# Retail Mac OS 8.1 hardware recording, 2026-10-17

The user supplied `D:/VODs/2026-10-17 19-51-31.mkv` and confirms a known-good
retail 8.1 disc. Treat that as the reproduction input. The recording is
20.991 seconds, 1920x1080 at 60 fps; SHA-256:
`123d0577aabf0149016fc3c407373bc1839dafdd32534cc4c307333f8abfed6b`.
The checkout at analysis was `a9f8bc2` (`no-boot-troubleshooting`); this is
checkout provenance, not a verified hash of the fitted hardware artifact.

## What the recording establishes

The attempt ends at Sad Mac `0000000F / 00000001`. The displayed counters
remain `RST=0001, ROM=0001` through the relevant transition and end of the
clip. It does not show another machine reset or retirement at the monitored
ROM startup addresses. Other user-reported failures remain separate cases.

| Approximate clip time | Fault count (hex) | LAST: vector / format / PC / address / SSW |
| --- | --- | --- |
| Before 18.72 s | `0049` | `02 / 7 / 40805F04 / F1FFFFFF / 0125` |
| 18.72 s | `004A` | `02 / 7 / 408253CC / B6DB6DB6 / 0105` |
| 18.82 s | `0086` | `02 / 7 / 408046AC / 50F81C00 / 0525` |
| About 20.9 s | `304F` | `02 / 7 / 408046AC / 50F81C00 / 0525` |

The exact overlay font was decoded from cropped frames, with zero mismatched
glyph pixels for these readings. Times are approximate: the displayed
snapshot follows the event and the extraction resamples the recording.
The intermediate `408253CC` fault remains visible for several frames;
looking only at the final screenshot would miss it.

`RAM1` is already occupied by `02 / 7 / 4080DC1A / 00FFFF00 / 0505`.
The ROM code there validates a pointer, with bus-error-vector restoration at
`4080DC22`. It is not an automatic indication of the final fatal fault.
Likewise, the earlier `40805F04` byte read is in the ROM's slot-address
probe code. The low-address execution heuristic cannot select the first
fatal error reliably in this attempt.

## The useful fault is a pointer dereference

Disassembling the local pristine `releases/boot0.rom` gives:

```asm
408253BE  C0FC 0012       MULU.W  #18,D0
408253C2  206B 004A       MOVEA.L $4A(A3),A0
408253C6  2050            MOVEA.L (A0),A0
408253C8  2068 0004       MOVEA.L $4(A0),A0
408253CC  2050            MOVEA.L (A0),A0     ; recorded fault
408253CE  D1C0            ADDA.L  D0,A0
408253D0  4E75            RTS
```

SSW `0105` describes a longword supervisor-data read with the ATC fault bit
clear. The recorded failing address is therefore the bad pointer being
dereferenced, not the address of the RAM cell that supplied it.

`B6DB6DB6` is one of the ROM's RAM-test patterns. Its fill routine at
`408477E6..4084782C` writes repeated register groups loaded from the pattern
table at `408478D6`. Existing independent boot logs also show that routine
writing `B6DB6DB6` into RAM, for example at `0000B950` and `0000B95C`
(`scratch/ap68040_faster_boot_long.log`). Those example locations are not
identified as the actual pointer source in this hardware attempt.

The evidence suggests a pointer chain reached RAM-test contents. It does
not distinguish an uninitialized object, a wrong effective address, stale
cache data, a lost write, or an incorrect loaded/register value. No CPU
behavior fix follows from the pattern alone.

The later `408046AC` instruction is `TST.B (A2,D2.L)`, in a register/alias
probe routine. Address `50F81C00` is in the VIA register mirror space;
SSW `0525` has ATC set and describes a byte supervisor-data read. The flood
starts after the pointer fault, during the visible failure path. Treat it
as subsequent activity; it does not establish that VIA or SCSI caused the
initial failure.

## Short directed check and next capture

A scratch probe reproduces the exact instruction sequence above after
replacing the observed RAM-test value with a valid pointer chain. It sweeps
all 32 byte offsets across two lines, including split longwords, under four
conditions: data cache disabled, write-through, copyback, and serialized
cache-inhibited. Fixed and randomized platform latency both pass:
70,228 and 98,933 clocks, respectively, with each execution under 0.25 s.
This checks the direct dependency/alignment/cache cases, not the complete
hardware memory implementation, MMU state, or OS startup.

Analysis artifacts are in `scratch/ap68040_diag/hardware_195131/`:
`make_pointer_probe.py`, `pointer_chain.s`, `pointer_{fixed,waits}.log`,
`rom.dis`, `read_overlay.py`, and `overlay_{end,fine}.json`.

The observer now exports a successful load's logical PC, effective address,
and committed result, including cache hits. The overlay records the three
MOVEA results at `408253C2/C6/C8` and freezes them at an access error at
`408253CC`. Rows `P0`, `P1`, and `P2` show address, value, and a validity bit;
`PTR 1` indicates the chain is frozen. A new invocation clears older tail
entries, so incomplete captures do not look complete. Guest resets retain
the frozen values; Off/On clears them.

On the next user-run build, enable CPU diagnostics before the same attempt
and capture the failure screen with all nine rows. If `PTR=1` and the rows
are valid, compare P0's value to P1's address, and P1's value plus four to
P2's address. This distinguishes a pointer-chain dependency/address mismatch
from a load that actually returned the RAM-test pattern. P2's address then
identifies the logical source cell to investigate; it is not automatically
a physical SDRAM address.

Verification of the addition: capture/order/freeze/rearm/reset/CDC tests pass;
native fixed/random adapter regressions pass at 3,093/4,121 clocks; all 512
pointer-probe load events have the expected PC/address/value tuple; platform
Verilator lint passes with existing warnings. The expanded 512-pixel overlay
was rendered and inspected (`pointer_preview.png`, synthetic data).
No full-machine boot simulation, Quartus build, or hardware deployment ran.
