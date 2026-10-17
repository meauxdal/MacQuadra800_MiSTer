#!/usr/bin/env bash
# QUARTUS_SIM_LIB=/path/to/quartus/eda/sim_lib/altera_mf.v bash scripts/test_ap68040_ram.sh
set -euo pipefail
cd "$(dirname "$0")/.."
R=rtl/ap68040_faster/rtl
W=scratch/ap68040_ram
mkdir -p "$W"
MODEL=${QUARTUS_SIM_LIB:-/mnt/c/intelFPGA_lite/17.0/quartus/eda/sim_lib/altera_mf.v}
[[ -f "$MODEL" ]] || { echo 'Set QUARTUS_SIM_LIB to Quartus eda/sim_lib/altera_mf.v'; exit 1; }
for implementation in inferred m10k; do
    options=()
    model=()
    if [[ "$implementation" == m10k ]]; then
        options+=(-DAP68040_ALTERA_RAM=1)
        model+=("$MODEL")
    fi
    iverilog -g2012 -s tb_ap68040_ram -I"$R" "${options[@]}" \
        -o "$W/$implementation.vvp" "$R/gen/ap68040_upkg.sv" "$R/ap68040_ram.sv" \
        "${model[@]}" verilator/tb_ap68040_ram.sv > "$W/$implementation.log" 2>&1 || { tail -30 "$W/$implementation.log"; exit 1; }
    vvp "$W/$implementation.vvp" | tee -a "$W/$implementation.log"
done
