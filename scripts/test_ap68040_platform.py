#!/usr/bin/env python3
"""Short native CPU programs through the Q800 service and real SDRAM RTL.

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
    parser.add_argument('--image', type=Path, default=ROOT / 'scratch/ap68040_os81_cd/installer.iso')
    parser.add_argument('--cpu', choices=['legacy', 'faster', 'both'], default='both')
    parser.add_argument('--no-build', action='store_true')
    parser.add_argument('--case', help='run one named SCSI matrix case')
    args = parser.parse_args()
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
    for cpu in (['legacy', 'faster'] if args.scsi and args.cpu == 'both' else
                [args.cpu] if args.scsi else ['faster']):
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


def scsi_compare(args, vasm):
    if not args.image.is_file():
        raise SystemExit(f'missing ISO: {args.image}')
    digest = hashlib.sha1(args.image.read_bytes()).hexdigest()
    print(f'image SHA1={digest}', flush=True)
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
        traces = []
        for cpu in cpus:
            trace = WORK / f'{name}_{cpu}.trace'
            output = run([WORK / f'obj_{cpu}/Vtb_native_platform', '+prog=' + str(binary),
                          '+ram_program', '+image=' + str(args.image), '+trace=' + str(trace),
                          f'+dest={dest}', f'+bytes={size}',
                          f'+offset={lba * (2048 if target == 3 else 512)}', f'+host_delay={delay}'],
                         WORK / f'{name}_{cpu}.log')
            if 'PASS SCSI' not in output:
                raise SystemExit(f'{name}/{cpu}: missing SCSI success')
            print(f'{name}/{cpu}: ' + next(l for l in output.splitlines() if l.startswith('PASS SCSI')), flush=True)
            traces.append(normalized_trace(trace))
        if len(traces) == 2:
            for label, left, right in zip(('bus', 'host', 'RAM'), traces[0], traces[1]):
                for index in range(max(len(left), len(right))):
                    a = left[index] if index < len(left) else '<end>'
                    b = right[index] if index < len(right) else '<end>'
                    if a != b:
                        raise SystemExit(f'FIRST DIVERGENCE {name} {label}[{index}]: legacy {a}; faster {b}')
            print(f'{name}: MATCH bus={len(traces[0][0])} host={len(traces[0][1])} bytes={size}', flush=True)


if __name__ == '__main__':
    main()
