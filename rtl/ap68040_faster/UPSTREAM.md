# AP68040 faster import

Source: https://github.com/apolkosnik/AP68040/tree/faster

Pinned commit: `ab4d83d36c33ea6bc5d0bbf19feb5df11a8de892`
(`DMU: MOVE16 from a cached source copies the hit way's line`). Imported
from the clean local `faster` checkout on 2026-10-17. License: GPL v2 or later.

The active Q800 CPU is this pipelined implementation. The previous sequential
fork remains in `../ap68040/` for historical comparisons and regression tools;
it is not in the default FPGA or full-machine simulator source list.

Local changes to upstream:

* `rtl/ap68040.qip`: ordered Quartus source list and include paths.
* `rtl/ap68040_ram.sv`: put the two ports of `ap68040_tdp` in separate
  clocked processes. Quartus 17.0.2 on Windows implemented the original
  single-process form as 1,510 registers and zero RAM bits in an isolated
  64x22 test. The separate-process form uses 58 registers and 1,408 block
  memory bits, retaining the existing explicit read bypasses. Same-address
  simultaneous RAM writes remain unsupported by the physical memory.
* `tb/tb_ap68040.sv`: mark the completion result and halt-status variables
  `verilator public_flat`. Verilator 5.032 otherwise localized `result`
  into separate generated C++ functions: the CPU wrote the pass signature,
  but the bench's waiting coroutine never saw it and timed out.

Q800 integration lives outside this directory: `../wombat_cpu_ap68040.sv`,
`../wombat_ap68040_bus.sv`, and `../quadra800.sv`. Generated decode and
microcode tables are included. `tools/ucode.py` regenerates them.
