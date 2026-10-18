#!/usr/bin/env python3
"""Short CPU programs through the Q800 service and real SDRAM RTL.

Run under WSL: python3 scripts/test_ap68040_platform.py
No FPGA build, deployment, or full guest OS boot is involved.
"""
from pathlib import Path
import os
import shutil
import subprocess
import argparse
import hashlib
import struct
import json

ROOT = Path(__file__).resolve().parents[1]
WORK = ROOT / 'scratch/ap68040_native_platform'
RTL = ROOT / 'rtl'
CPU = RTL / 'ap68040_faster/rtl'
FIXTURE = ROOT / 'scripts/fixtures/ap68040_faster'


def run(argv, logfile):
    with logfile.open('w') as log:
        result = subprocess.run([str(x) for x in argv], cwd=ROOT,
                                stdout=log, stderr=subprocess.STDOUT)
    output = logfile.read_text(errors='replace')
    if result.returncode:
        raise SystemExit(f'{logfile}:\n{output[-5000:]}')
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--scsi', action='store_true', help='compare prior and faster CPU READ(10)')
    parser.add_argument('--recovery', action='store_true', help='compare MMU faults, frames and RTE recovery')
    parser.add_argument('--collect-differences', action='store_true',
                        help='recovery only: retain all differences and return failure after the matrix')
    parser.add_argument('--image', type=Path, default=ROOT / 'scratch/ap68040_os81_cd/installer.iso')
    parser.add_argument('--cpu', choices=['legacy', 'faster', 'both'], default='both')
    parser.add_argument('--no-build', action='store_true')
    parser.add_argument('--case', help='run one named SCSI matrix case')
    parser.add_argument('--snapshot', type=Path,
                        default=ROOT / 'scratch/ap68040_os81_cd/native/ram_snapshot_255131649.bin',
                        help='if present, verify saved SCSI page attributes before testing')
    args = parser.parse_args()
    if args.scsi and args.recovery:
        parser.error('select one differential suite at a time')
    WORK.mkdir(parents=True, exist_ok=True)
    vasm = os.environ.get('VASM') or shutil.which('vasmm68k_mot')
    if not vasm or not shutil.which('verilator'):
        raise SystemExit('Run under WSL with Verilator and vasmm68k_mot on PATH (or set VASM).')
    # Keep the protocol-checked chip model; flatten only its storage so the
    # program can be loaded without an associative entry per halfword.
    model = (ROOT / 'verilator/tb_sdram.sv').read_text()
    model = model[model.index('module sdram_model'):]
    for old, new in [
        ('bit [15:0] mem [int];', 'bit [15:0] mem [0:33554431];'),
        ("mem.exists(k) ? mem[k] : 16'hFFFF", 'mem[k]'),
        ("if (!mem.exists(k)) mem[k] = 16'hFFFF;", ''),
    ]:
        assert old in model, old
        model = model.replace(old, new)
    flat = WORK / 'sdram_model_flat.sv'
    flat.write_text('`timescale 1ps/1ps\n' + model)
    sources = [CPU / 'ap68040_pkg.sv', CPU / 'gen/ap68040_upkg.sv']
    sources += [p for p in sorted(CPU.glob('*.sv')) if p.name != 'ap68040_pkg.sv']
    sources += [CPU / 'fpu/ap040_fpu.v']
    sources += [RTL / p for p in [
        'wombat_cpu_ap68040.sv', 'wombat_ap68040_bus.sv', 'quadra800.sv',
        'wombat_store_buffer.sv', 'wombat_bus32.sv', 'sdram_beat32.sv', 'sdram.sv',
        'iosb.sv', 'via6522.sv', 'dafb.sv', 'rtc3430042.sv', 'easc.sv',
        'ncr53c96.sv', 'sonic_mbx.sv', 'cd_audio.sv', 'scsi_cache.sv', 'adb.sv',
        'scc.v', 'uart/txuart.v', 'uart/rxuart.v', 'dpram.v',
    ]]
    sources += [FIXTURE / 'tb_native_platform.sv', flat,
                ROOT / 'verilator/altddio_out_stub.v']
    host_sources = [FIXTURE / 'platform_scsi_host.cpp', ROOT / 'verilator/sim/cd_window.cpp',
                    ROOT / 'verilator/sim/mac/mac_cdrom_resp.cpp', ROOT / 'verilator/sim/mac/mac_cdrom_play.cpp']
    differential = args.scsi or args.recovery
    for cpu in (['legacy', 'faster'] if differential and args.cpu == 'both' else
                [args.cpu] if differential else ['faster']):
        cpu_sources = sources
        cpu_root = CPU
        defines = []
        if cpu == 'legacy':
            cpu_root = RTL / 'ap68040/rtl'
            cpu_sources = [p for p in sources if not p.is_relative_to(CPU) and p.name not in
                           ('wombat_cpu_ap68040.sv', 'wombat_ap68040_bus.sv')]
            cpu_sources = [*sorted(cpu_root.glob('*.v')), RTL / 'wombat_cpu.sv', *cpu_sources]
            defines = ['-DQ800_LEGACY_CPU=1']
        if not args.no_build:
            print(f'Building {cpu} platform fixture...', flush=True)
            run(['verilator', '--binary', '--timing', '-j', '8', '-Wno-fatal',
                 '-Wno-WIDTH', '-Wno-TIMESCALEMOD', '-Wno-PINMISSING', '-Wno-IMPLICIT',
                 '-Wno-BLKLOOPINIT', '-DSIMULATION=1', '--top-module', 'tb_native_platform',
                 '--Mdir', WORK / f'obj_{cpu}', '-I' + str(RTL), '-I' + str(cpu_root),
                 '-I' + str(CPU / 'fpu'), *defines,
                 '-CFLAGS', '-I' + str(ROOT / 'verilator/sim') + ' -I' + str(ROOT / 'verilator/sim/mac'),
                 *cpu_sources, *host_sources], WORK / f'build_{cpu}.log')
    if args.scsi:
        scsi_compare(args, vasm)
        return
    if args.recovery:
        recovery_compare(args, vasm)
        return
    programs = [('pointer_chain', FIXTURE / 'pointer_chain.s', False)]
    programs += [(p, RTL / f'ap68040_faster/tb/asm/{p}.s', True)
                 for p in ('t_fpexc', 't_fpu', 't_stld')]
    for name, source, from_ram in programs:
        binary = WORK / f'{name}.bin'
        run([vasm, '-quiet', '-Fbin', '-m68040', '-no-opt', '-o', binary, source],
            WORK / f'{name}_asm.log')
        args = ['+ram_program'] if from_ram else []
        output = run([WORK / 'obj_faster/Vtb_native_platform', '+prog=' + str(binary), *args],
                     WORK / f'{name}.log')
        if not any(line.startswith('PASS native CPU') for line in output.splitlines()):
            raise SystemExit(f'{name}: missing success marker')
        print(name + ': ' + next(line for line in output.splitlines()
                                if line.startswith('PASS native CPU')))


def recovery_compare(args, vasm):
    cpus = ['legacy', 'faster'] if args.cpu == 'both' else [args.cpu]
    names = ['read_invalid', 'write_invalid', 'write_protected', 'split_read',
             'split_write', 'fifo_control', 'fifo_dest_fault', 'rmw_protected', 'ifetch_invalid',
             'reg_write_nonzero', 'reg_write_zero', 'observed_odd_word']
    cases = [(name + suffix, kind, cache) for cache, suffix in [(0, ''), (1, '_icache'), (2, '_copyback')]
             for kind, name in enumerate(names)]
    if args.case:
        cases = [c for c in cases if c[0] == args.case]
        if not cases:
            raise SystemExit(f'unknown recovery case: {args.case}')
    report = dict(cases=[], result='RUNNING', contract_failures=[])
    report_path = WORK / ('recovery_results' + ('_' + args.case if args.case else '') + '.json')
    report_path.write_text(json.dumps(report, indent=2) + '\n')
    for name, kind, cache in cases:
        binary = WORK / f'recovery_{name}.bin'
        run([vasm, '-quiet', '-Fbin', '-m68040', '-no-opt', f'-DKIND={kind}', f'-DCACHE={cache}',
             '-o', binary, FIXTURE / 'mmu_recovery.s'], WORK / f'recovery_{name}_asm.log')
        case = dict(name=name, kind=kind, cache=cache,
                    program_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(), runs={})
        normalized = []
        raw = []
        for cpu in cpus:
            trace = WORK / f'recovery_{name}_{cpu}.trace'
            logfile = WORK / f'recovery_{name}_{cpu}.log'
            output = run([WORK / f'obj_{cpu}/Vtb_native_platform', '+ram_program', '+recovery',
                          '+prog=' + str(binary), '+trace=' + str(trace)], logfile)
            if 'PASS recovery capture' not in output:
                raise SystemExit(f'{name}/{cpu}: missing recovery capture')
            memory, bus = {}, []
            for line in trace.read_text().splitlines():
                fields = line.split()
                if fields[0] == 'M':
                    address, value = int(fields[1], 16), int(fields[2], 16)
                    memory[address], memory[address+1] = value >> 8, value & 255
                elif fields[0] == 'B':
                    bus.append(line)
            def value(address, size=4):
                return int.from_bytes(bytes(memory[a] for a in range(address, address+size)), 'big')
            frame = bytes(memory[a] for a in range(0x3100, 0x313c))
            result = {f'{offset:02x}': value(0x3200+offset) for offset in range(0, 0x48, 4)}
            faults = result['00']
            if faults != (0 if kind == 5 else 1):
                raise SystemExit(f'{name}/{cpu}: unexpected fault count {faults}')
            if faults:
                if value(0x3106, 2) != 0x7008 or not value(0x310c, 2) & 0x400:
                    raise SystemExit(f'{name}/{cpu}: incorrect format/vector or missing ATC bit')
                if value(0x3102) != (0x6000 if kind == 8 else result['28']):
                    raise SystemExit(f'{name}/{cpu}: incorrect stacked restart PC')
            # Independent architectural checks, not just equality of two cores.
            want_d4 = (0x55667788 if kind == 0 else 0x1234bbcc if kind == 3 else
                       0 if kind == 10 else 0x12343344 if kind == 11 else 0x12345678)
            want_a1 = 0x10004 if kind in (0, 1, 2) else 0x12003 if kind == 4 else 0x10001 if kind in (5, 6) else 0x10000
            if result['18'] != want_d4 or result['1c'] != 0x87654321 or result['14'] != want_a1:
                raise SystemExit(f'{name}/{cpu}: register/EA recovery mismatch: {result}')
            want_a0 = (0x18004 if kind in (1, 2, 4) else 0x12001 if kind == 3 else
                       0x50f10020 if kind in (5, 6) else 0xffffb1df if kind == 11 else 0x18000)
            if result['10'] != want_a0:
                raise SystemExit(f'{name}/{cpu}: source postincrement incorrect: {result}')
            if kind in (1, 2) and result['30'] != 0x11223344:
                raise SystemExit(f'{name}/{cpu}: repaired store data mismatch')
            if kind == 4 and (result['34'] != 0xaa112233 or result['38'] != 0x44000000):
                raise SystemExit(f'{name}/{cpu}: repaired split store data mismatch: {result}')
            if kind == 7 and result['3c'] != 0x12345688:
                raise SystemExit(f'{name}/{cpu}: RMW store was lost or applied twice')
            if kind in (9, 10) and result['30'] != want_d4:
                raise SystemExit(f'{name}/{cpu}: reduced register store did not complete')
            want_sr = 0x2708 if kind == 3 else 0x2704 if kind in (8, 10) else 0x2700
            if result['24'] >> 16 != want_sr:
                raise SystemExit(f'{name}/{cpu}: incorrect CCR after recovery')
            if kind == 11 and (value(0x310c, 2) != 0x545 or value(0x3114) != 0xffffb1df):
                raise SystemExit(f'{name}/{cpu}: observed odd-word frame shape did not reproduce')
            fifo_reads = [b for b in bus if b.startswith('B 0 0 50f10020 ')]
            contract = None
            if kind in (5, 6):
                delivered = result['30'] >> 24
                if delivered not in (0x11, 0x22) or len(fifo_reads) not in (3, 4):
                    raise SystemExit(f'{name}/{cpu}: unexpected FIFO recovery outcome')
                contract = delivered == 0x11 and result['20'] == 0x22330000 and len(fifo_reads) == 3
                if kind == 5 and not contract:
                    raise SystemExit(f'{name}/{cpu}: no-fault FIFO control failed')
                if not contract:
                    report['contract_failures'].append(f'{name}/{cpu}: serialized FIFO source consumed twice')
            # Inactive WB payloads are not an architectural contract. Preserve
            # all 60 raw bytes, compare their payload only when V is set.
            architectural = bytearray(frame)
            for status_offset, payload_offsets in [(14, (24, 28)), (16, (32, 36)), (18, (40, 44))]:
                if not int.from_bytes(frame[status_offset:status_offset+2], 'big') & 0x80:
                    for offset in payload_offsets:
                        architectural[offset:offset+4] = b'\0'*4
            raw.append(frame)
            normalized.append((bytes(architectural), result, bus))
            case['runs'][cpu] = dict(frame_hex=frame.hex(), results=result, fifo_reads=fifo_reads,
                                     single_consume=contract, log=str(logfile), trace=str(trace),
                                     platform_result=next(l for l in output.splitlines() if l.startswith('PASS native CPU')))
            print(f'{name}/{cpu}: faults={faults}' +
                  (f' FIFO single-consume={contract} reads={len(fifo_reads)}' if contract is not None else ' recovery checks PASS'), flush=True)
        if len(normalized) == 2 and normalized[0] != normalized[1]:
            case['result'] = 'DIVERGENCE'
            report['result'] = 'DIVERGENCE'
            case['differing_fields'] = []
            case['frame_byte_differences'] = [i for i in range(60) if normalized[0][0][i] != normalized[1][0][i]]
            for label, left, right in zip(('frame', 'results', 'device accesses'), normalized[0], normalized[1]):
                if left != right:
                    case['differing_fields'].append(label)
            if args.collect_differences:
                print(f'{name}: DIVERGENCE {case["differing_fields"]} frame_offsets={case["frame_byte_differences"]}', flush=True)
                report['cases'].append(case)
                report_path.write_text(json.dumps(report, indent=2) + '\n')
                continue
            report['cases'].append(case)
            report_path.write_text(json.dumps(report, indent=2) + '\n')
            for label, left, right in zip(('frame', 'results', 'device accesses'), normalized[0], normalized[1]):
                if left != right:
                    if label == 'frame':
                        detail = ', '.join(f'+{i:02x}: {left[i]:02x}/{right[i]:02x}'
                                           for i in case['frame_byte_differences'])
                        raise SystemExit(f'FIRST DIVERGENCE {name} frame (legacy/faster) {detail}; see {report_path}')
                    raise SystemExit(f'FIRST DIVERGENCE {name} {label}: legacy={left!r}; faster={right!r}; see {report_path}')
        case['result'] = ('CONTRACT_FAILURE' if any(x['single_consume'] is False for x in case['runs'].values())
                          else 'MATCH' if len(normalized) == 2 else 'PASS (single CPU)')
        if len(raw) == 2:
            case['inactive_frame_byte_differences'] = [i for i in range(60) if raw[0][i] != raw[1][i]]
        report['cases'].append(case)
        report_path.write_text(json.dumps(report, indent=2) + '\n')
        print(f'{name}: {case["result"]}', flush=True)
    if report['result'] != 'DIVERGENCE':
        report['result'] = 'CONTRACT_FAILURE' if report['contract_failures'] else 'COMPLETE'
    report_path.write_text(json.dumps(report, indent=2) + '\n')
    if report['contract_failures']:
        raise SystemExit(f'{len(report["contract_failures"])} serialized-source contract failures; '
                         f'comparison={report["result"]}; recorded in {report_path}')
    if report['result'] == 'DIVERGENCE':
        raise SystemExit(f'Recovery differences recorded in {report_path}')


def normalized_trace(path):
    """Keep side effects and RAM exact; collapse timing-only polling repeats.

    HPS order is compared independently of CPU accesses: faster instruction
    execution legitimately changes the interleaving, not the request contract.
    """
    bus, host, ram = [], [], []
    polls = {}
    for line in path.read_text().splitlines():
        if line.startswith('H '):
            host.append(line)
        elif line.startswith('R '):
            ram.append(line)
        elif line.startswith('B '):
            fields = line.split()
            poll = fields[1] == '0' and fields[3] in ('50f10040', '50f10070')
            # Poll count and intermediate not-ready values depend on CPU speed.
            if poll:
                polls[fields[3]] = line
            else:
                # Retain the last sampled status/FIFO values at each actual
                # transaction, so phase, TC0 and ready values remain checked.
                bus.extend(polls.values())
                polls.clear()
                bus.append(line)
    return bus, host, ram


def check_saved_scsi_map(snapshot):
    if not snapshot.is_file():
        print('Saved RAM snapshot absent; using recorded descriptors (see differential report).', flush=True)
        return []
    ram = snapshot.read_bytes()
    def word(address):
        return struct.unpack_from('>I', ram, address)[0]
    records = []
    for root in (0x03fffa00, 0x03feea00):
        addresses = [0x50f10000, 0x50f50100]
        if root == 0x03feea00:
            addresses += [0x00f10000, 0x00f50100]
        for logical in addresses:
            desc = word(root + ((logical >> 25) & 127) * 4)
            assert desc & 2, 'missing root'
            desc = word((desc & 0xfffffe00) + ((logical >> 18) & 127) * 4)
            assert desc & 2, 'missing pointer'
            desc = word((desc & 0xffffff80) + ((logical >> 13) & 31) * 4)
            if desc & 3 == 2:
                desc = word(desc & 0xfffffffc)
            expected = 0x50f10059 if logical & 0x40000 == 0 else 0x50f50079
            if desc != expected:
                raise SystemExit(f'Saved mapping changed: root={root:08x} LA={logical:08x} desc={desc:08x}, expected={expected:08x}')
            records.append(dict(root=f'{root:08x}', logical=f'{logical:08x}', descriptor=f'{desc:08x}'))
    print('Saved SCSI mappings verified: base CM=2, mirrored bulk port CM=3, including low alias.', flush=True)
    return records


def scsi_compare(args, vasm):
    if not args.image.is_file():
        raise SystemExit(f'missing ISO: {args.image}')
    image = args.image.read_bytes()
    digest = hashlib.sha1(image).hexdigest()
    print(f'image SHA1={digest}', flush=True)
    report = dict(image=str(args.image), image_sha1=digest,
                  saved_mappings=check_saved_scsi_map(args.snapshot), cases=[])
    cpus = ['legacy', 'faster'] if args.cpu == 'both' else [args.cpu]
    cases = [
        # name, target, LBA, blocks, destination, mixed widths, HPS delay, mode
        ('cd_control', 3, 16, 1, 0x10000, False, 40, 0),
        ('disk_control', 0, 64, 1, 0x10000, False, 40, 0),
        ('cd_rom_cache', 3, 16, 1, 0x10000, False, 40, 1),
        ('cd_rom_mixed_odd', 3, 16, 1, 0x10001, True, 40, 1),
        ('cd_mmu', 3, 16, 1, 0x10000, False, 40, 2),
        ('cd_mmu_alias', 3, 16, 1, 0x10003, True, 40, 3),
        ('cd_mmu_boundary_slow', 3, 17, 3, 0x11ffb, True, 16000, 2),
        ('disk_mmu_boundary_slow', 0, 7, 3, 0x11ffd, True, 16000, 2),
    ]
    if args.case:
        cases = [c for c in cases if c[0] == args.case]
        if not cases:
            raise SystemExit(f'unknown case: {args.case}')
    for name, target, lba, blocks, dest, mixed, delay, mode in cases:
        size = blocks * (2048 if target == 3 else 512)
        binary = WORK / f'{name}.bin'
        defines = [f'-D{k}={v}' for k, v in dict(TARGET=target, LBA=lba, BLOCKS=blocks,
                                               BYTES=size, DEST=dest, MODE=mode,
                                               IOBASE=0x00f10000 if mode == 3 else 0x50f10000).items()]
        if mixed:
            defines.append('-DMIXED=1')
        run([vasm, '-quiet', '-Fbin', '-m68040', '-no-opt', *defines, '-o', binary,
             FIXTURE / 'scsi_read10.s'], WORK / f'{name}_asm.log')
        offset = lba * (2048 if target == 3 else 512)
        expected = image[offset:offset+size]
        program = binary.read_bytes()
        if len(program) > 0x8000 or len(expected) != size:
            raise SystemExit('invalid program/expected range')
        binary.write_bytes(program.ljust(0x8000, b'\0') + expected)
        traces = []
        case = dict(name=name, target=target, lba=lba, blocks=blocks, dest=dest,
                    mixed=mixed, host_delay=delay, mode=mode, bytes=size,
                    program_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(), runs={})
        for cpu in cpus:
            trace = WORK / f'{name}_{cpu}.trace'
            output = run([WORK / f'obj_{cpu}/Vtb_native_platform', '+prog=' + str(binary),
                          '+ram_program', '+image=' + str(args.image), '+trace=' + str(trace),
                          f'+dest={dest}', f'+bytes={size}',
                          f'+offset={offset}', f'+host_delay={delay}'],
                         WORK / f'{name}_{cpu}.log')
            if 'PASS SCSI' not in output:
                raise SystemExit(f'{name}/{cpu}: missing SCSI success')
            print(f'{name}/{cpu}: ' + next(l for l in output.splitlines() if l.startswith('PASS SCSI')), flush=True)
            traces.append(normalized_trace(trace))
            wanted_ram = [f'R {dest+i:08x} {b:02x}' for i, b in enumerate(expected)]
            if traces[-1][2] != wanted_ram:
                raise SystemExit(f'{name}/{cpu}: RAM trace differs from independent ISO bytes')
            case['runs'][cpu] = dict(trace=str(trace), log=str(WORK / f'{name}_{cpu}.log'),
                                     normalized_sha256=hashlib.sha256(repr(traces[-1]).encode()).hexdigest(),
                                     platform_result=next(l for l in output.splitlines() if l.startswith('PASS native CPU')))
        if len(traces) == 2:
            for label, left, right in zip(('bus', 'host', 'RAM'), traces[0], traces[1]):
                for index in range(max(len(left), len(right))):
                    a = left[index] if index < len(left) else '<end>'
                    b = right[index] if index < len(right) else '<end>'
                    if a != b:
                        raise SystemExit(f'FIRST DIVERGENCE {name} {label}[{index}]: legacy {a}; faster {b}')
            print(f'{name}: MATCH bus={len(traces[0][0])} host_records={len(traces[0][1])} bytes={size}', flush=True)
        case['result'] = 'MATCH' if len(traces) == 2 else 'PASS (single CPU)'
        report['cases'].append(case)
        (WORK / 'scsi_results.json').write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__':
    main()
