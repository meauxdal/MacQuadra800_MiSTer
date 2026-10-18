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
    parser.add_argument('--pdma-reduction', action='store_true',
                        help='reduce ROM NOP/device-read cancellation with real SCSI PDMA')
    parser.add_argument('--recovery', action='store_true', help='compare MMU faults, frames and RTE recovery')
    parser.add_argument('--root-recovery', action='store_true',
                        help='compare distinct URP/SRP, user A7, MOVES and nested RTE recovery')
    parser.add_argument('--interrupts', action='store_true', help='compare real VIA timer IRQ/STOP/RTE paths')
    parser.add_argument('--rom-copy', action='store_true', help='replay actual ROM BlockMove and MOVE16 routines')
    parser.add_argument('--rom-scsi', action='store_true', help='execute original ROM SCSI Manager READ(10)')
    parser.add_argument('--rom-host-delay', type=int, default=40,
                        help='ROM SCSI suite: clocks before each HPS response')
    parser.add_argument('--trap-calls', action='store_true', help='ROM copy suite: call via real ROM A-line dispatcher')
    parser.add_argument('--collect-differences', action='store_true',
                        help='recovery suites: retain all differences and return failure after the matrix')
    parser.add_argument('--image', type=Path, default=ROOT / 'scratch/ap68040_os81_cd/installer.iso')
    parser.add_argument('--cpu', choices=['legacy', 'faster', 'both'], default='both')
    parser.add_argument('--no-build', action='store_true')
    parser.add_argument('--case', help='run one named differential case')
    parser.add_argument('--snapshot', type=Path,
                        default=ROOT / 'scratch/ap68040_os81_cd/native/ram_snapshot_255131649.bin',
                        help='if present, verify saved SCSI page attributes before testing')
    args = parser.parse_args()
    if sum((args.scsi, args.pdma_reduction, args.recovery, args.root_recovery, args.interrupts, args.rom_copy, args.rom_scsi)) > 1:
        parser.error('select one differential suite at a time')
    if args.trap_calls and not args.rom_copy:
        parser.error('--trap-calls requires --rom-copy')
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
    differential = args.scsi or args.pdma_reduction or args.recovery or args.root_recovery or args.interrupts or args.rom_copy or args.rom_scsi
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
    if args.scsi or args.pdma_reduction:
        scsi_compare(args, vasm)
        return
    if args.recovery:
        recovery_compare(args, vasm)
        return
    if args.root_recovery:
        root_recovery_compare(args, vasm)
        return
    if args.interrupts:
        interrupt_compare(args, vasm)
        return
    if args.rom_copy:
        rom_copy_compare(args, vasm)
        return
    if args.rom_scsi:
        rom_scsi_compare(args, vasm)
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


def rom_scsi_compare(args, vasm):
    rom = ROOT / 'releases/boot0.rom'
    rom_digest = hashlib.sha256(rom.read_bytes()).hexdigest()
    if rom_digest != '7d9cb8c3bae0e26171adf9f24bedf10bf6371ae3c9bdbcdfd3b94e5350099fb6':
        raise SystemExit('ROM differs from the verified Quadra image')
    snapshot = args.snapshot.read_bytes()
    if int.from_bytes(snapshot[0xe54:0xe58], 'big') != 0x40807460:
        raise SystemExit('saved SCSI trap mapping changed')
    image = args.image.read_bytes()
    cpus = ['legacy', 'faster'] if args.cpu == 'both' else [args.cpu]
    cases = [(f'{device}_{state}', target, 16 if target == 3 else 64, mode, 0x10000, 1, 5)
             for device, target in [('cd', 3), ('disk', 0)]
             for mode, state in enumerate(('uncached', 'rom_cache'))]
    cases += [(f'cd_{shape}_{state}', 3, 17, mode, dest, blocks, selector)
              for shape, dest, blocks, selector in [('rblind', 0x10000, 1, 8),
                                                     ('odd_boundary', 0x11ffb, 3, 5)]
              for mode, state in enumerate(('uncached', 'rom_cache'))]
    if args.case:
        cases = [c for c in cases if c[0] == args.case]
        if not cases:
            raise SystemExit(f'unknown ROM SCSI case: {args.case}')
    report_path = WORK / ('rom_scsi_results' + ('_' + args.case if args.case else '') + '.json')
    report = dict(result='RUNNING', rom_sha256=rom_digest, snapshot_sha256=hashlib.sha256(snapshot).hexdigest(),
                  image_sha1=hashlib.sha1(image).hexdigest(), cases=[])
    for name, target, lba, mode, dest, blocks, selector in cases:
        block_size = 2048 if target == 3 else 512
        size = blocks * block_size
        offset = lba * block_size
        expected = image[offset:offset+size]
        if len(expected) != size:
            raise SystemExit('image too short')
        binary = WORK / f'rom_scsi_{name}.bin'
        run([vasm, '-quiet', '-Fbin', '-m68040', '-no-opt', f'-DTARGET={target}',
             f'-DLBA={lba}', f'-DBYTES={size}', f'-DMODE={mode}', f'-DDEST={dest}',
             f'-DBLOCKS={blocks}', f'-DREADSEL={selector}', '-o', binary,
             FIXTURE / 'rom_scsi_read10.s'], WORK / f'rom_scsi_{name}_asm.log')
        program = bytearray(binary.read_bytes().ljust(0x8000, b'\0'))
        # Recorded low-memory globals, OS/toolbox trap tables and resident
        # SCSI manager table/queues. Guest code starts at $2000; preserve its
        # reset/exception vectors and result log, not the old CPU state.
        program[0x100:0x2000] = snapshot[0x100:0x2000]
        program[0x7000:0x8000] = snapshot[0x7000:0x8000]
        binary.write_bytes(program + expected)
        case = dict(name=name, target=target, lba=lba, bytes=size, mode=mode,
                    dest=dest, blocks=blocks, selector=selector, host_delay=args.rom_host_delay,
                    program_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(), runs={})
        report['cases'].append(case)
        report_path.write_text(json.dumps(report, indent=2) + '\n')
        for cpu in cpus:
            trace = WORK / f'rom_scsi_{name}_{cpu}.trace'
            logfile = WORK / f'rom_scsi_{name}_{cpu}.log'
            case['runs'][cpu] = dict(log=str(logfile), trace=str(trace))
            try:
                output = run([WORK / f'obj_{cpu}/Vtb_native_platform', '+ram_program', '+recovery',
                              '+prog=' + str(binary), '+trace=' + str(trace), '+rom=' + str(rom),
                              '+rom_lines', '+rom_jitter', '+operand_trace', '+image=' + str(args.image),
                              f'+dest={dest}', f'+bytes={size}', f'+offset={offset}',
                              f'+host_delay={args.rom_host_delay}'], logfile)
            except SystemExit:
                report['result'] = case['result'] = 'FAIL'
                report_path.write_text(json.dumps(report, indent=2) + '\n')
                raise
            trace_lines = trace.read_text().splitlines()
            wanted = [f'R {dest+i:08x} {b:02x}' for i, b in enumerate(expected)]
            if [line for line in trace_lines if line.startswith('R ')] != wanted or 'PASS SCSI' not in output:
                report['result'] = case['result'] = 'ORACLE_FAILURE'
                report_path.write_text(json.dumps(report, indent=2) + '\n')
                raise SystemExit(f'{name}/{cpu}: direct SDRAM/ISO oracle failed')
            captured = {}
            for line in trace_lines:
                parts = line.split()
                if parts[0] == 'M':
                    address, half = int(parts[1], 16), int(parts[2], 16)
                    captured[address], captured[address+1] = half >> 8, half & 255
            results = bytes(captured[a] for a in range(0x3200, 0x3218))
            if int.from_bytes(results[:4], 'big') != 5 or any(results[4:18]) or int.from_bytes(results[20:24], 'big') != 0xe000:
                report['result'] = case['result'] = 'ROM_RESULT_FAILURE'
                report_path.write_text(json.dumps(report, indent=2) + '\n')
                raise SystemExit(f'{name}/{cpu}: SCSI API result/mailbox checks failed: {results.hex()}')
            case['runs'][cpu]['mailbox_hex'] = results.hex()
            bulk_reads = [line for line in trace_lines if line.startswith('B 0 2 50f50100 ')]
            case['runs'][cpu]['bulk_long_reads'] = len(bulk_reads)
            if dest % 4 == 0 and len(bulk_reads) != size // 4:
                raise SystemExit(f'{name}/{cpu}: extra/missing bulk reads: {len(bulk_reads)}')
            case['runs'][cpu]['platform_result'] = next(l for l in output.splitlines() if l.startswith('PASS native CPU'))
            print(f'{name}/{cpu}: original ROM SCSI Manager + independent {size}-byte RAM check PASS', flush=True)
        case['result'] = 'MATCH' if len(cpus) == 2 else 'PASS (single CPU)'
        report_path.write_text(json.dumps(report, indent=2) + '\n')
    report['result'] = 'COMPLETE'
    report_path.write_text(json.dumps(report, indent=2) + '\n')


def rom_copy_compare(args, vasm):
    rom = ROOT / 'releases/boot0.rom'
    digest = hashlib.sha256(rom.read_bytes()).hexdigest()
    if digest != '7d9cb8c3bae0e26171adf9f24bedf10bf6371ae3c9bdbcdfd3b94e5350099fb6':
        raise SystemExit('ROM differs from the verified Quadra image')
    cpus = ['legacy', 'faster'] if args.cpu == 'both' else [args.cpu]
    shapes = [('small', 0x10003, 0x12005, 7), ('odd', 0x10001, 0x12003, 65),
              ('line', 0x10000, 0x12000, 513), ('overlap_back', 0x10000, 0x10003, 257),
              ('overlap_forward', 0x10003, 0x10000, 257),
              ('source_page', 0x11ffb, 0x10ff3, 513),
              ('dest_page', 0x1000b, 0x11ff3, 513), ('large', 0x10000, 0x12000, 4096)]
    if args.trap_calls:
        shapes = [shape for shape in shapes if shape[0] in ('small', 'odd', 'large')]
    cases = [(f'{"trap_" if args.trap_calls else ""}{routine}_{shape}_{state_name}', entry, src, dest, length, state)
             for routine, entry in [('blockmove', 0x4080ca10), ('move16', 0x40884400)]
             for state, state_name in enumerate(('uncached', 'writethrough', 'copyback'))
             for shape, src, dest, length in shapes]
    if args.case:
        cases = [c for c in cases if c[0] == args.case]
        if not cases:
            raise SystemExit(f'unknown ROM copy case: {args.case}')
    report_path = WORK / ('rom_' + ('trap_' if args.trap_calls else '') + 'copy_results' +
                         ('_' + args.case if args.case else '') + '.json')
    report = dict(result='RUNNING', rom=str(rom), rom_sha256=digest, cases=[], trap_calls=args.trap_calls,
                  arena_pattern='SHAKE256(Q800 ROM BlockMove independent arena v1), 16384 bytes')
    for name, entry, src, dest, length, state in cases:
        initial = hashlib.shake_256(b'Q800 ROM BlockMove independent arena v1').digest(0x4000)
        expected = bytearray(initial)
        expected[dest-0x10000:dest-0x10000+length] = expected[src-0x10000:src-0x10000+length]
        if length and src != dest and initial == expected:
            raise SystemExit('copy oracle must detect an omitted copy')
        binary = WORK / f'rom_copy_{name}.bin'
        run([vasm, '-quiet', '-Fbin', '-m68040', '-no-opt', *(['-DTRAPCALL=1'] if args.trap_calls else []), f'-DENTRY={entry}',
             f'-DSRC={src}', f'-DDST={dest}', f'-DLENGTH={length}', f'-DSTATE={state}',
             '-o', binary, FIXTURE / 'rom_blockmove.s'], WORK / f'rom_copy_{name}_asm.log')
        program = binary.read_bytes()
        if len(program) > 0x8000:
            raise SystemExit('ROM copy program overlaps expected arena')
        binary.write_bytes(program.ljust(0x8000, b'\0') + expected + initial)
        case = dict(name=name, entry=f'{entry:08x}', src=src, dest=dest, length=length, state=state,
                    program_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(), runs={})
        report['cases'].append(case)
        report_path.write_text(json.dumps(report, indent=2) + '\n')
        for cpu in cpus:
            trace = WORK / f'rom_copy_{name}_{cpu}.trace'
            logfile = WORK / f'rom_copy_{name}_{cpu}.log'
            try:
                output = run([WORK / f'obj_{cpu}/Vtb_native_platform', '+ram_program', '+recovery',
                              '+prog=' + str(binary), '+trace=' + str(trace), '+rom=' + str(rom),
                              '+rom_lines', '+rom_jitter'], logfile)
            except SystemExit:
                report['result'] = case['result'] = 'FAIL'
                case['runs'][cpu] = dict(log=str(logfile), trace=str(trace))
                report_path.write_text(json.dumps(report, indent=2) + '\n')
                raise
            memory = {}
            for line in trace.read_text().splitlines():
                fields = line.split()
                if fields[0] == 'M':
                    address, value = int(fields[1], 16), int(fields[2], 16)
                    memory[address], memory[address+1] = value >> 8, value & 255
            def value(address):
                return int.from_bytes(bytes(memory[a] for a in range(address, address+4)), 'big')
            observed = [value(a) for a in range(0x3200, 0x3228, 4)]
            if observed[:7] != [0, 0xe000, 0x456789ab, 0x56789abc, 0x6789abcd, 0x789abcde, 0x89abcdef] or observed[9] != 0x4000:
                raise SystemExit(f'{name}/{cpu}: ROM return/register/oracle checks failed: {observed}')
            case['runs'][cpu] = dict(log=str(logfile), trace=str(trace), results=observed,
                                     platform_result=next(l for l in output.splitlines() if l.startswith('PASS native CPU')),
                                     rom_result=next(l for l in output.splitlines() if l.startswith('ROM replay')))
            print(f'{name}/{cpu}: original ROM copy + 16KiB independent arena check PASS', flush=True)
        case['result'] = 'MATCH' if len(cpus) == 2 else 'PASS (single CPU)'
        if len(cpus) == 2 and case['runs']['legacy']['results'] != case['runs']['faster']['results']:
            report['result'] = case['result'] = 'DIVERGENCE'
            report_path.write_text(json.dumps(report, indent=2) + '\n')
            raise SystemExit(f'{name}: differing ROM return observations; see {report_path}')
        report_path.write_text(json.dumps(report, indent=2) + '\n')
    report['result'] = 'COMPLETE'
    report_path.write_text(json.dumps(report, indent=2) + '\n')


def interrupt_compare(args, vasm):
    cpus = ['legacy', 'faster'] if args.cpu == 'both' else [args.cpu]
    cases = [(f't{timer+1}_{waitname}_{mode_name}', timer, wait, mode)
             for mode, mode_name in enumerate(('uncached', 'rom_cache', 'mmu_alias'))
             for timer in range(2)
             for wait, waitname in enumerate(('rmw', 'stop', 'pending_stop'))]
    if args.case:
        cases = [c for c in cases if c[0] == args.case]
        if not cases:
            raise SystemExit(f'unknown interrupt case: {args.case}')
    report = dict(result='RUNNING', cases=[])
    report_path = WORK / ('interrupt_results' + ('_' + args.case if args.case else '') + '.json')
    for name, timer, wait, mode in cases:
        binary = WORK / f'interrupt_{name}.bin'
        run([vasm, '-quiet', '-Fbin', '-m68040', '-no-opt', f'-DTIMER={timer}',
             f'-DWAIT={wait}', f'-DMODE={mode}', '-o', binary, FIXTURE / 'via_interrupts.s'],
            WORK / f'interrupt_{name}_asm.log')
        case = dict(name=name, timer=timer+1, wait=wait, mode=mode,
                    program_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(), runs={})
        for cpu in cpus:
            trace = WORK / f'interrupt_{name}_{cpu}.trace'
            logfile = WORK / f'interrupt_{name}_{cpu}.log'
            output = run([WORK / f'obj_{cpu}/Vtb_native_platform', '+ram_program', '+recovery',
                          '+prog=' + str(binary), '+trace=' + str(trace)], logfile)
            memory = {}
            for line in trace.read_text().splitlines():
                parts = line.split()
                if parts[0] == 'M':
                    address, value = int(parts[1], 16), int(parts[2], 16)
                    memory[address], memory[address+1] = value >> 8, value & 255
            def value(address, size=4):
                return int.from_bytes(bytes(memory[a] for a in range(address, address+size)), 'big')
            observed = dict(irq_count=value(0x3200), rounds=value(0x3204),
                            saved_sr=value(0x3208, 2), saved_pc=value(0x320c),
                            format_vector=value(0x3210, 2), ifr_before=value(0x3214, 1),
                            ifr_after=value(0x3215, 1), data=value(0x3218),
                            expected_data=value(0x321c), expected_irqs=value(0x3220),
                            final_sp=value(0x3224))
            flag = 0x40 if timer == 0 else 0x20
            if not (observed['irq_count'] == observed['rounds'] == observed['expected_irqs'] == 32 and
                    observed['saved_sr'] & 0x2700 == 0x2000 and observed['format_vector'] == 0x64 and
                    observed['ifr_before'] & (flag | 0x80) == flag | 0x80 and
                    observed['ifr_after'] & flag == 0 and observed['final_sp'] == 0xe000 and
                    observed['data'] == observed['expected_data'] == 0x11223344 + (512 if wait == 0 else 0)):
                raise SystemExit(f'{name}/{cpu}: independent interrupt checks failed: {observed}')
            case['runs'][cpu] = dict(observed=observed, log=str(logfile), trace=str(trace),
                                     platform_result=next(l for l in output.splitlines()
                                                          if l.startswith('PASS native CPU')))
            print(f'{name}/{cpu}: 32 real timer interrupts, register/RTE/data checks PASS', flush=True)
        # IRQ instruction timing, saved CCR, and the unused IFR source flags
        # legitimately vary. Every run separately checks the active contract.
        case['result'] = 'MATCH' if len(cpus) == 2 else 'PASS (single CPU)'
        report['cases'].append(case)
        report_path.write_text(json.dumps(report, indent=2) + '\n')
    report['result'] = 'COMPLETE'
    report_path.write_text(json.dumps(report, indent=2) + '\n')


def root_recovery_compare(args, vasm):
    """Root selection and nested returns have independent physical oracles.

    Keep incoming/result flags equal for ordinary MOVE stores: the separate
    --recovery suite already isolates the known stacked-CCR difference.
    This experiment must distinguish URP from SRP even when both CPUs agree.
    """
    cpus = ['legacy', 'faster'] if args.cpu == 'both' else [args.cpu]
    names = ['user_read_invalid', 'user_write_invalid', 'user_a7_write_invalid',
             'moves_read_user_invalid', 'moves_write_user_protected',
             'user_ifetch_invalid', 'user_nested_read_invalid']
    cases = [(name + suffix, kind, cache)
             for cache, suffix in [(0, ''), (1, '_icache'), (2, '_copyback')]
             for kind, name in enumerate(names)]
    if args.case:
        cases = [c for c in cases if c[0] == args.case]
        if not cases:
            raise SystemExit(f'unknown root recovery case: {args.case}')
    report = dict(cases=[], result='RUNNING', roots=dict(srp='00004000', urp='00005000'))
    report_path = WORK / ('root_recovery_results' + ('_' + args.case if args.case else '') + '.json')
    report_path.write_text(json.dumps(report, indent=2) + '\n')
    for name, kind, cache in cases:
        binary = WORK / f'root_recovery_{name}.bin'
        run([vasm, '-quiet', '-Fbin', '-m68040', '-no-opt', f'-DKIND={kind}', f'-DCACHE={cache}',
             '-o', binary, FIXTURE / 'mmu_root_recovery.s'], WORK / f'root_recovery_{name}_asm.log')
        case = dict(name=name, kind=kind, cache=cache,
                    program_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(), runs={})
        normalized = []
        for cpu in cpus:
            trace = WORK / f'root_recovery_{name}_{cpu}.trace'
            logfile = WORK / f'root_recovery_{name}_{cpu}.log'
            output = run([WORK / f'obj_{cpu}/Vtb_native_platform', '+ram_program', '+recovery',
                          '+prog=' + str(binary), '+trace=' + str(trace)], logfile)
            if 'PASS recovery capture' not in output:
                raise SystemExit(f'{name}/{cpu}: missing recovery capture')
            memory = {}
            for line in trace.read_text().splitlines():
                fields = line.split()
                if fields[0] == 'M':
                    address, value = int(fields[1], 16), int(fields[2], 16)
                    memory[address], memory[address+1] = value >> 8, value & 255
            def value(address, size=4):
                return int.from_bytes(bytes(memory[a] for a in range(address, address+size)), 'big')
            result = {f'{offset:02x}': value(0x3200+offset) for offset in range(0, 0x60, 4)}
            faults = 2 if kind == 6 else 1
            frames = [bytes(memory[a] for a in range(base, base+60))
                      for base in [0x3100, 0x3140][:faults]]
            checks = []
            def check(label, actual, expected):
                if actual != expected:
                    checks.append(f'{label}: got {actual:08x}, expected {expected:08x}')
            check('fault count', result['00'], faults)
            check('outer ISP frame address', result['04'], 0xe000-60)
            check('inner ISP frame address', result['08'], 0xe000-60-28-60 if kind == 6 else 0)
            check('final ISP', result['3c'], 0xe000)
            check('final USP', result['20'], 0xd004 if kind == 2 else 0xd000)
            check('final A0', result['10'], 0xd000)
            check('final A1', result['14'], 0x10000 if kind == 5 else 0x10004)
            check('final D4', result['18'], 0x11223344 if kind in (0, 3, 6) else
                  0x2468ace0 if kind == 5 else 0x12345678)
            check('preserved D5', result['1c'], 0x87654321)
            check('resumed SR', result['24'] >> 16,
                  0x2704 if kind in (3, 4) else 0x0700)
            check('user physical data', result['30'], 0x12345678 if kind in (1, 4) else
                  0x40de1234 if kind == 2 else 0x11223344)
            check('supervisor decoy', result['34'], 0x55667788)
            check('user stack source', result['38'], 0x40de1234)
            check('user trap count', result['50'], 0 if kind in (3, 4) else 1)
            check('nested SRP read result', result['54'], 0x55667788 if kind == 6 else 0)
            check('preserved SFC', result['58'], 1)
            check('preserved DFC', result['5c'], 1)
            check('original user data descriptor', result['40'],
                  0x18004 + (0x39 if cache == 2 else 0x59) if kind == 4 else
                  0x18000 + (0x39 if cache == 2 else 0x59) if kind == 5 else 0)
            check('final user physical mapping', result['48'] & 0xffffe000, 0x18000)
            check('final supervisor physical mapping', result['4c'] & 0xffffe000, 0x10000)
            architectural_frames = []
            for index, frame in enumerate(frames):
                def field(offset, size=4):
                    return int.from_bytes(frame[offset:offset+size], 'big')
                check(f'frame {index} format/vector', field(6, 2), 0x7008)
                check(f'frame {index} FA', field(20), 0x6000 if kind == 5 else 0x10000)
                check(f'frame {index} PC', field(2), result['0c'] if index else
                      0x6000 if kind == 5 else result['28'])
                expected_ssw = (0x505 if index else 0x502 if kind == 5 else
                                0x401 if kind in (1, 2, 4) else 0x501)
                check(f'frame {index} SSW', field(12, 2), expected_ssw)
                # Ordinary MOVE stores use equal incoming/result flags so
                # the known CCR difference cannot hide a root/stack failure.
                expected_super = index > 0 or kind in (3, 4)
                check(f'frame {index} saved privilege', field(0, 2) & 0x2000,
                      0x2000 if expected_super else 0)
                if index == 0:
                    check('outer saved SR', field(0, 2), 0x2704 if kind in (3, 4) else 0x0700)
                active = bytearray(frame)
                for status, payload in [(14, (24, 28)), (16, (32, 36)), (18, (40, 44))]:
                    if not field(status, 2) & 0x80:
                        for offset in payload:
                            active[offset:offset+4] = b'\0'*4
                architectural_frames.append(bytes(active))
            case['runs'][cpu] = dict(results=result, frames_hex=[f.hex() for f in frames],
                                     check_failures=checks, log=str(logfile), trace=str(trace),
                                     platform_result=next(l for l in output.splitlines()
                                                          if l.startswith('PASS native CPU')))
            normalized.append((architectural_frames, result))
            if checks:
                case['result'] = 'CONTRACT_FAILURE'
                report['cases'].append(case)
                report['result'] = 'CONTRACT_FAILURE'
                report_path.write_text(json.dumps(report, indent=2) + '\n')
                raise SystemExit(f'{name}/{cpu}: ' + '; '.join(checks) + f'; see {report_path}')
            print(f'{name}/{cpu}: {faults} fault(s), distinct-root/stack/data checks PASS', flush=True)
        differences = []
        if len(normalized) == 2:
            for index, (left, right) in enumerate(zip(normalized[0][0], normalized[1][0])):
                differences += [f'frame {index} +{i:02x}: {a:02x}/{b:02x}'
                                for i, (a, b) in enumerate(zip(left, right)) if a != b]
            differences += [f'result +{offset}: {normalized[0][1][offset]:08x}/{normalized[1][1][offset]:08x}'
                            for offset in result if normalized[0][1][offset] != normalized[1][1][offset]]
        case['differences'] = differences
        case['result'] = 'DIVERGENCE' if differences else 'MATCH' if len(cpus) == 2 else 'PASS (single CPU)'
        report['cases'].append(case)
        if differences:
            report['result'] = 'DIVERGENCE'
        report_path.write_text(json.dumps(report, indent=2) + '\n')
        print(f'{name}: {case["result"]}' + (f' {differences}' if differences else ''), flush=True)
        if differences and not args.collect_differences:
            raise SystemExit(f'FIRST DIVERGENCE: {name}; see {report_path}')
    if report['result'] == 'RUNNING':
        report['result'] = 'COMPLETE'
    report_path.write_text(json.dumps(report, indent=2) + '\n')
    if report['result'] != 'COMPLETE':
        raise SystemExit(f'Root recovery differences recorded in {report_path}')


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
    report_path = WORK / ('pdma_reduction_results.json' if args.pdma_reduction else 'scsi_results.json')
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
    if args.pdma_reduction:
        cases = [(f'pdma_{state}_{shape}', 3, 16, 1, 0x10000, False, 40, mode)
                 for mode, state in enumerate(('uncached', 'serialized'))
                 for shape in ('consecutive', 'separated')]
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
        if args.pdma_reduction:
            defines.append('-DPDMA_REDUCTION=1')
            if name.endswith('_separated'):
                defines.append('-DPDMA_SPACED=1')
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
        report['cases'].append(case)
        for cpu in cpus:
            trace = WORK / f'{name}_{cpu}.trace'
            logfile = WORK / f'{name}_{cpu}.log'
            case['runs'][cpu] = dict(trace=str(trace), log=str(logfile))
            try:
                output = run([WORK / f'obj_{cpu}/Vtb_native_platform', '+prog=' + str(binary),
                              '+ram_program', '+operand_trace', '+image=' + str(args.image), '+trace=' + str(trace),
                              f'+dest={dest}', f'+bytes={size}',
                              f'+offset={offset}', f'+host_delay={delay}'],
                             logfile)
            except SystemExit:
                case['result'] = 'FAIL'
                report_path.write_text(json.dumps(report, indent=2) + '\n')
                raise
            if 'PASS SCSI' not in output:
                raise SystemExit(f'{name}/{cpu}: missing SCSI success')
            print(f'{name}/{cpu}: ' + next(l for l in output.splitlines() if l.startswith('PASS SCSI')), flush=True)
            traces.append(normalized_trace(trace))
            if args.pdma_reduction:
                bulk_reads = [line for line in traces[-1][0] if line.startswith('B 0 2 50f50100 ')]
                if len(bulk_reads) != size // 4:
                    raise SystemExit(f'{name}/{cpu}: extra/missing bulk reads: {len(bulk_reads)}')
            wanted_ram = [f'R {dest+i:08x} {b:02x}' for i, b in enumerate(expected)]
            if traces[-1][2] != wanted_ram:
                raise SystemExit(f'{name}/{cpu}: RAM trace differs from independent ISO bytes')
            case['runs'][cpu] = dict(trace=str(trace), log=str(logfile),
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
        report_path.write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__':
    main()
