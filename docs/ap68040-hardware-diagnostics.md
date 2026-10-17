# AP68040 on-screen diagnostics

The TCI candidate did not change the user's hardware symptoms. This observer
is for locating an actual failure; it is not another proposed boot fix.

After the next user-run hardware build, select **CPU diagnostics → On** in
the OSD **before resetting for a failing boot attempt**. This switch does not
reset the machine. Turning it Off and then On clears the capture. Guest resets
preserve it. No change to PRAM, RAM size, or disk image is needed.

The top-left overlay fits the 512-pixel monitor mode and shows:

| Row | Meaning |
| --- | --- |
| `AP040 PC` | Current backend/WB PC, sampled once per video frame. |
| `BUS … STATE …` | Current platform transaction address and the state word below. The address may be stale when no request is active. |
| `RST … ROM … FAULT …` | Hex counters: machine-reset rising edges; retirement at this ROM's startup addresses `$8C`/`$4080008C`; selected synchronous faults. Counts begin when enabled. |
| `LAST vv f pppppppp aaaaaaaa ssss` | Latest selected fault: vector, frame format, logical PC, fault address, SSW. Cache-push fault addresses are physical. |
| `RAM1 vv f pppppppp aaaaaaaa ssss` | First selected fault after retirement at a low logical address `$10000..$07FFFFFF`; frozen until the switch is rearmed. This is a boot-stage heuristic, not physical address translation. |
| `RST PC … RAM …` | Backend PC when the most recent machine reset began; whether the low-address retirement heuristic has fired. |

The selected vectors are 2 (access error), 3 (address error), 4 (illegal
instruction), 8 (privilege violation), and 14 (format error). Normal A-line,
F-line, trap, interrupt and trace traffic does not overwrite the capture.
An early fault can be an intentional ROM probe; a displayed fault alone is
not proof that it caused the visible failure. All-zero fault rows mean no
selected event has been recorded in that slot.

For a hang, two screenshots several seconds apart show whether PC or bus state
is still moving. For a restart loop, `ROM` advancing with `RST` unchanged
distinguishes re-entry at the known ROM startup instruction from a machine
reset. `RAM1` preserves the first later-stage fault while subsequent ROM
probes can update `LAST`. A halt is visible in STATE bit 6 even if it did not
generate a new fault event.

## STATE word

| Bits | Meaning |
| --- | --- |
| 0 / 1 / 2 | Platform request / write / instruction read |
| 3 / 4 / 5 | Platform acknowledge / bus error / HPS stall hold |
| 6 / 7 | CPU halted / retirement pulse |
| 10:8 | Native bridge CPU state: 0 idle, 1 wait, 2 reply, 3 retry, 4 parked, 5 resume |
| 14:11 | DMA state: 0 idle, 1 grant, 2 start, 3 look, 4 memory, 5 terminate, 6 next, 7 done |
| 15 | TCI pin, active low |
| 18:16 | IPL pins, active low |
| 19 / 20 / 21 | Native address output enabled / TS asserted / LOCK asserted |
| 22 / 23 | Native TEA asserted / TA asserted |
| 27:24 | Native PST |
| 31 | Machine reset asserted |

The recorder observes CPU signals without acknowledging, stalling, retrying,
or modifying memory transactions. Video consumes a coherent snapshot through
a request/acknowledgement handshake; its pixel path cannot feed back into the
CPU. The low PC field and `$A040` marker of the existing debug packet remain.
The retired PC is separately registered so it refers to the instruction that
generated the retirement pulse, rather than a younger uop now in WB.

## Verification

`make -C verilator tb_ap68040_diag` checks capture selection, first-fault
retention, guest resets, coherent transfer between unrelated test clocks,
rearming, rejection of legacy packets, and disabled output. A synthetic
512-pixel raster was rendered and inspected at
`scratch/ap68040_diag/preview.png`; it is not hardware failure evidence.

`bash scripts/test_ap68040_faster.sh` also checks the native access-error event
against the faulting instruction bytes, format, address and SSW. Fixed and
random latency runs pass at 3,093 and 4,121 clocks. Production CPU/platform
Verilator lint passes with existing warnings. No Quartus, synthesis, fitting,
hardware deployment or full boot simulation was run for these changes.
