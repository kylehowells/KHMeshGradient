#!/usr/bin/env python3
"""Inspect a caller-supplied local RenderBox Mach-O and optional Metal library.

Research only. Extracted Apple instructions/AIR stay in ignored DerivedData.
No framework code is copied into KHMeshGradient or public experiment artifacts.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import struct
import subprocess


def command(args):
    return subprocess.run(args, check=True, capture_output=True, text=True).stdout


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--library', type=Path)
    parser.add_argument('--output', type=Path, default=Path('DerivedData/GeometryProbe/inspection'))
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    symbols = command(['nm', '-arch', 'arm64', str(args.binary)])
    demangled = subprocess.run(['c++filt'], input=symbols, capture_output=True, text=True, check=True).stdout
    selected = [line for line in demangled.splitlines() if 'MeshGradient::' in line and
                any(name in line for name in ['make_buffers(', 'PatchBuffer::commit_patch(', 'PatchBuffer::PatchBuffer('])]
    summary = {'binarySHA256': hashlib.sha256(args.binary.read_bytes()).hexdigest(),
               'uuid': command(['xcrun', 'dwarfdump', '--uuid', str(args.binary)]).split()[1],
               'symbols': selected, 'shaderModules': []}
    for line in selected:
        address = int(line.split()[0], 16)
        all_addresses = sorted(int(s.split()[0], 16) for s in symbols.splitlines() if re.match(r'^[0-9a-f]+ [tT] ', s))
        end = next(a for a in all_addresses if a > address)
        text = command(['xcrun', 'lldb', '-b', '-o', f'target create "{args.binary}"',
                        '-o', f'disassemble -s {address:#x} -e {end:#x}', '-o', 'quit'])
        (args.output / f'{address:x}.assembly.txt').write_text(text)
    if args.library:
        data = args.library.read_bytes()
        summary['librarySHA256'] = hashlib.sha256(data).hexdigest()
        position, index = 0, 0
        while True:
            position = data.find(b'\xde\xc0\x17\x0b', position)
            if position < 0:
                break
            _, version, offset, size, _ = struct.unpack_from('<5I', data, position)
            blob = data[position + offset:position + offset + size]
            if version == 0 and blob.startswith(b'BC\xc0\xde') and b'accumulator_mesh_gradient_' in blob:
                bitcode = args.output / f'mesh-{index}.bc'
                llvm = args.output / f'mesh-{index}.ll'
                bitcode.write_bytes(blob)
                subprocess.run(['xcrun', 'clang', '-S', '-emit-llvm', '-x', 'ir', str(bitcode), '-o', str(llvm)], check=True)
                ir = llvm.read_text()
                summary['shaderModules'].append({'bitcodeSHA256': hashlib.sha256(blob).hexdigest(),
                                                'entryPoints': re.findall(r'^define .*?@(accumulator_mesh_gradient_\w+)\(', ir, re.M),
                                                'hasFragmentColorSampling': bool(re.search(r'^define .*sample_mesh_gradient', ir, re.M)),
                                                'hasHalfVectorArithmetic': '<4 x half>' in ir})
                index += 1
            position += 4
    (args.output / 'metadata.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(json.dumps(summary, indent=2))


if __name__ == '__main__':
    main()
