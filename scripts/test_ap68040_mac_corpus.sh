#!/usr/bin/env bash
# Run the existing Mac silicon-oracled payloads on the production faster
# wrapper + wombat_bus32. Payload compilation stays in preboot/sim040.
set -euo pipefail
cd "$(dirname "$0")/.."
R=rtl/ap68040_faster/rtl
W=${AP68040_MAC_WORK_DIR:-scratch/ap68040_mac_tests}
P=${AP68040_MAC_PAYLOAD_DIR:-SingleStepTests/preboot/sim040/build}
mkdir -p "$W"
sources=("$R/ap68040_pkg.sv" "$R/gen/ap68040_upkg.sv")
for file in "$R"/*.sv; do [[ "$file" == "$R/ap68040_pkg.sv" ]] || sources+=("$file"); done
verilator --binary --timing -j 8 -Wno-fatal -Wno-WIDTH -Wno-TIMESCALEMOD \
    -I"$R" -I"$R/fpu" --top-module tb_ap68040_mac_corpus --Mdir "$W/obj" \
    "${sources[@]}" "$R/fpu/ap040_fpu.v" rtl/wombat_cpu_ap68040.sv \
    rtl/wombat_ap68040_bus.sv rtl/wombat_bus32.sv verilator/tb_ap68040_mac_corpus.sv \
    > "$W/build.log" 2>&1 || { tail -40 "$W/build.log"; exit 1; }
suites=("${@:-cpu}")
failed=0
for suite in "${suites[@]}"; do
    case "$suite" in
        cpu) oracle=cpu/hardware_quadra800_2026-08-28.jsonl ;;
        fpu) oracle=fpu/hardware_quadra800_2026-08-28.jsonl ;;
        saverestore) oracle=cpu_fpu/hardware_saverestore_2026-08-28.jsonl ;;
        integration) oracle=cpu_fpu/hardware_quadra800_2026-08-28.jsonl ;;
        mmu) oracle=mmu/hardware_full_quadra800_2026-08-28.jsonl ;;
        *) echo "unknown suite: $suite" >&2; exit 1 ;;
    esac
    python3 - "$P/payload_${suite}_sim.bin" "$W/$suite.hex" <<'PY'
import sys
from pathlib import Path
payload=Path(sys.argv[1]).read_bytes()
if len(payload)&1: payload+=b'\0'
with open(sys.argv[2],'w') as out:
    out.write('@0\n0008 0000 0004 0000\n@20000\n')
    for i in range(0,len(payload),2): out.write(payload[i:i+2].hex()+'\n')
PY
    if ! stdbuf -oL "$W/obj/Vtb_ap68040_mac_corpus" +prog="$W/$suite.hex" \
        +results="$W/results_$suite.bin" +maxcycles="${MAXCYCLES:-2500000000}" \
        | tee "$W/run_$suite.log"; then
        failed=1
        continue
    fi
    if ! python3 - "$W/results_$suite.bin" "$W/results_$suite.jsonl" "SingleStepTests/results/$oracle" <<'PY'
import json, sys
from pathlib import Path
raw=Path(sys.argv[1]).read_bytes().replace(b'\0',b'')
rows=[line for line in raw.splitlines() if line.strip()]
for row in rows: json.loads(row)
expected=[line for line in Path(sys.argv[3]).read_bytes().splitlines() if line.startswith(b'{')]
if len(rows)!=len(expected):
    raise SystemExit(f'Incomplete corpus: expected {len(expected)} rows, received {len(rows)}')
Path(sys.argv[2]).write_bytes(b'\n'.join(rows)+b'\n')
print(f'{len(rows)} result rows')
PY
    then
        failed=1
        continue
    fi
    if ! python3 SingleStepTests/gen/score_vs_oracle.py "$suite" \
        "SingleStepTests/results/$oracle" "$W/results_$suite.jsonl" --flat-env \
        | tee "$W/score_$suite.log"; then
        failed=1
    fi
done
exit "$failed"
