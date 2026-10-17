# Fresh investigation: shared AP68040 integration failures

## User's requested change in direction

The user explicitly wants a new chat with **high reasoning** because the
previous investigation did not advance actual OS boot. The objective is
reliable Macintosh OS startup after integrating the pipelined AP68040 `faster`
CPU. Investigate the shared CPU/platform contract across all failure modes.
Do not make the Mac OS 8.1 installer's Sad Mac the defining reproduction.

User-confirmed symptoms on the same fitted build:

* HDA images are not properly recognized; some end at flashing question mark.
* Some attempts hang at Happy Mac.
* Some reach Happy Mac and immediately restart.
* Some CD attempts retain a movable mouse while waiting, then enter a reset
  loop with no further interactivity.
* One retail Mac OS 8.1 ISO attempt shows Sad Mac 0000000F/00000001 (bus error).
* Actual OS startup fails in every case, across images and RAM sizes.

Repeated PRAM resets and multiple RAM sizes have already been tried. These
are not remedies to propose again. A comment about importing Q800 persistence
was intended for the separate 605 chat and was explicitly retracted here.

The user rejects spending LLM time waiting through full Quadra boot
simulation. **Do not restart long full-machine boot runs or repeat the
installer-only approach.** Prefer source/contract analysis and short,
falsifiable, directed tests tied to observed or demonstrated mismatches.
Use existing traces and snapshots. Avoid another cycle of elaborate diagnostic
setup with no concrete integration finding.

## Constraints and checkout

* Local project: `C:\Workspace\Git\MacQuadra800_MiSTer`.
* Branch `faster-ap`, HEAD `a20d04c` (`faster-check-in-1`) at seed creation.
  Recheck status; the user can commit concurrently.
* Current uncommitted work: investigation notes and optional simulator PRAM
  loader in `verilator/sim.v`; earlier handoff doc is untracked. Preserve all.
* Reference CPU checkout `C:\Workspace\Git\AP68040`, branch `faster`.
* No Quartus, synthesis, fits, FPGA build, deployment, or hardware reboot. The
  user runs FPGA builds. Prepare a concrete justified change/instrumentation
  for their review if hardware validation becomes necessary.
* Do not message Dani or others. No subagents requested.
* WSL works with `require_escalated`; normal sandbox WSL has E_ACCESSDENIED.
  Verilator5.032, Python3 and compiler available there. Existing short tests
  and scratch-local m68k toolchain are already present.
* PowerShell expands Bash `$variables` in embedded command strings. Use script
  files for complex commands.

## Current state — old handoff's RUNNING section is obsolete

The previous chat is idle. All full-boot simulator runs were stopped. Do not
restart them automatically, and do not assume PIDs/session IDs in the older
handoff are current. Preserved data:

`scratch/ap68040_os81_cd/native/`, `legacy/`, `adbdiag/`

They did not reproduce the hardware boot failures. The first two were stopped
at roughly255M/340M simulator ticks, still before boot selection in a ROM ADB
wait. An earlier successful diagnostic-disk simulation spent220M..380M ticks
there before advancing. Calling those runs a permanent ADB stall was mistaken.
A replacement ADB-instrumented run was also stopped; optional ADB trace code
was removed. Do not resume that rabbit hole.

An ISO already verified and copied locally is
`scratch/ap68040_os81_cd/installer.iso`,420542464 bytes,
SHA1 `7900544de9a3653494262e9b8b1448295d66239d`.
It is one failing image, not the whole problem. Current hardware OSD was64MiB;
matching saved PRAM/RAM in simulations was only reproduction control.

## Evidence to retain, and its limits

The original all-in-one CPU-test HDA hangs at Happy Mac. In simulation its
custom screen wipe at F9001000, with TTRs0, corrupts low RAM. A modified probe
sets only DTT0=F900C060 before drawing. The probe completes all five suites on
the fitted hardware and writes results via SCSI. Original payloads unchanged.
This demonstrates covered CPU paths and that SCSI can work in this special
environment. It does **not** establish ROM/OS compatibility or fix general
boot. Avoid treating this probe workaround as a proven shared root cause.

Full hardware data and scorer logs:
`scratch/ap68040_mac_tests/hardware_20261017/results/`, `score_*.log`, `run.hda`.
Raw counts: CPU717, FPU270, save/restore8, MMU-full25 records, integration1328.
Default scorer reports zero real differences, with layout/environment/golden
classifications. This score is **not proof of universal CPU correctness**.
Read actual exclusions before relying on it.

The last chat audited raw results using
`scratch/ap68040_os81_cd/audit_raw_results.py`. All recorded exception vectors
match the silicon capture. Integration raw `actual` values all match silicon:
its1136/1328 display counter has176 vector11 cases and16 FPIAR-write rows that
expect12345678 but read5678, the silicon value. Do not label these192 cases
unexplained CPU failures; do not use the counter to dismiss integration bugs.

A real scorer limitation: the two MMU fault-frame windows are excluded
wholesale, beyond address normalization. Candidate format7 SSW0405 vs silicon
0485 differs in bit7, explicitly undefined by MC68040UM8.4.6.2; not a proven
defect. Candidate WB-valid fields are clear, while silicon WB2S/WB3S are0085.
The backend explicitly implements instruction restart with WB3S clear. A
scratch short test `fault_restart.s` (find under scratch/ap68040_os81_cd) faults
the destination of MOVE.L(A0)+,(A1)+ and returns with RTE. It passes in9ms:
one handler entry, both address regs increment once, intended write after
retry. That does not test an OS-style writeback handler or establish complete
68040 frame/recovery equivalence. Treat the frame difference as an open
contract question, not either a demonstrated boot cause or a disproven lead.

Existing directed adapter tests pass fixed/random latency, including basic
cache/DMA, parked-PDMA retry, RTD#4 with valid caller argument, and TST.W An.
RAM primitive byte-enables/read-latency equivalence passes inferred and Intel
models. Full packed-RAM CPU Verilator model could not compile Intel mixed
blocking/nonblocking assignments; don't claim it passed. Hardware results
exercise the fitted implementation but do not exhaust its behaviors.

## Recommended working approach — retain independent judgment

Start from integration source and the actual upstream interface, compare the
new wrapper/adapter to both native68040 requirements and the prior CPU's
platform contract. Identify concrete violations or coverage holes and rank
them by which observed symptoms they could explain. Do not assume one cause
must explain every symptom. Prioritize a demonstrable mismatch over generic
boot-trace collection or repeated small tests that mirror implementation.

Relevant code:

* `rtl/wombat_cpu_ap68040.sv` — new CPU wrapper.
* `rtl/wombat_ap68040_bus.sv` — native transfer conversion, retry/parking,
  interrupt acknowledge and SONIC/DMA snooping.
* `rtl/quadra800.sv`, `rtl/wombat_bus32.sv`, `MacQuadra800.sv` — platform
  cache/retained-line paths, memory decode, I/O, RAM and interrupt contracts.
* `rtl/ap68040_faster/rtl/` and reference upstream checkout.
* `rtl/wombat_cpu.sv` — prior integration, useful comparison, not automatically
  a correctness oracle.

Candidate areas to consider without anchoring: native bus handshake and
termination, sizes/lanes/bursts, cacheability/inhibit semantics, retained-line
and DMA coherency, lock/retry interactions, interrupt/AVEC handling, and
exception/writeback/restart semantics. Test the actual contract in question;
small passing tests only establish their stated narrow coverage.

Preserve existing work. Seek a short failing test or rigorous source evidence,
then fix and verify that issue. If hardware evidence is required, prepare a
specific low-overhead diagnostic with a clear question; the user controls
hardware builds. No OS boot fix or installer fault PC/address is yet proven.

Latest narrative and test details: read the end of
`docs/ap68040-boot-investigation.md`. The older
`docs/ap68040-os81-targeted-handoff.md` has useful provenance, but its narrow
installer objective and RUNNING-process instructions are superseded by this
brief and the user's correction in this chat.
