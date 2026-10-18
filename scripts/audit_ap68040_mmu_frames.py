#!/usr/bin/env python3
"""Decode preserved silicon/RTL MMU frames excluded by the corpus scorer.

This is a raw-field audit, not a relocation-normalized pass/fail scorer.
The stored hardware rows abort into the harness; they do not exercise RTE.
"""
import argparse
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCES = {
    'quadra_silicon': ROOT / 'SingleStepTests/results/mmu/hardware_full_quadra800_2026-08-28.jsonl',
    'archived_ap68040': ROOT / 'SingleStepTests/results/ap68040/verilator_mmu_2026-08-28.jsonl',
}


def audit_frames():
    records = []
    for source, path in SOURCES.items():
        for line in path.read_text().splitlines():
            row = json.loads(line)
            if row.get('vec') != 2 or not row.get('name', '').startswith('FAULT store'):
                continue
            candidates = []
            for window in row.get('windows', []):
                if not 0x3ff00 <= window['base'] < 0x40000:
                    continue
                data = bytes(window['bytes'])
                for offset in range(0, len(data)-59, 2):
                    if data[offset+6:offset+8] == b'\x70\x08':
                        candidates.append((window['base']+offset, data[offset:offset+60]))
            if len(candidates) != 1:
                raise ValueError(f'{source}/{row["name"]}: ambiguous or absent format-7 frame')
            address, frame = candidates[0]
            def field(offset, size):
                return int.from_bytes(frame[offset:offset+size], 'big')
            records.append(dict(source=source, file=str(path), name=row['name'],
                                frame_address=f'{address:08x}', frame_hex=frame.hex(),
                                sr=f'{field(0,2):04x}', pc=f'{field(2,4):08x}',
                                ssw=f'{field(12,2):04x}', fault_address=f'{field(20,4):08x}',
                                wb3_status=f'{field(14,2):04x}', wb3_valid=bool(field(14,2)&0x80),
                                wb3_address=f'{field(24,4):08x}', wb3_data=f'{field(28,4):08x}',
                                wb2_status=f'{field(16,2):04x}', wb2_valid=bool(field(16,2)&0x80),
                                wb2_address=f'{field(32,4):08x}', wb2_data=f'{field(36,4):08x}',
                                wb1_status=f'{field(18,2):04x}'))
    if len(records) != 4:
        raise ValueError(f'expected two store rows per source, got {len(records)}')
    return records


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path,
                        default=ROOT / 'scratch/ap68040_native_platform/archived_mmu_frame_audit.json')
    args = parser.parse_args()
    records = audit_frames()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(records, indent=2) + '\n')
    for row in records:
        print(f'{row["source"]}: {row["name"]}: SR={row["sr"]} SSW={row["ssw"]} '
              f'WB3S={row["wb3_status"]} WB3D={row["wb3_data"]} PC={row["pc"]}')
        print(f'  WB2S={row["wb2_status"]} WB2A={row["wb2_address"]} WB2D={row["wb2_data"]}')
