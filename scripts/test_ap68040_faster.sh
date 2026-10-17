#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
R=rtl/ap68040_faster/rtl
W=scratch/ap68040_faster_integration
mkdir -p "$W"
VASM=${VASM:-$(command -v vasmm68k_mot)}
"$VASM" -quiet -Fbin -m68040 -no-opt -o "$W/integration.bin" scripts/fixtures/ap68040_faster/integration.s
python3 rtl/ap68040_faster/tb/bin2hex.py "$W/integration.bin" "$W/integration.hex"
sources=("$R/ap68040_pkg.sv" "$R/gen/ap68040_upkg.sv")
for f in "$R"/*.sv; do [[ "$f" == "$R/ap68040_pkg.sv" ]] || sources+=("$f"); done
verilator --binary --timing -j 8 -Wno-fatal -Wno-WIDTH -Wno-TIMESCALEMOD \
    -I"$R" -I"$R/fpu" --top-module tb_ap68040_faster --Mdir "$W/obj" \
    "${sources[@]}" "$R/fpu/ap040_fpu.v" rtl/wombat_cpu_ap68040.sv \
    rtl/wombat_ap68040_bus.sv verilator/tb_ap68040_faster.sv > "$W/build.log" 2>&1 || { tail -40 "$W/build.log"; exit 1; }
"$W/obj/Vtb_ap68040_faster" +prog="$W/integration.hex" +check_diag
"$W/obj/Vtb_ap68040_faster" +prog="$W/integration.hex" +waits +check_diag
