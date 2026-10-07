#!/usr/bin/env python3
"""Repeat the same physical-device scene at several fixed tessellation densities.

Subdivisions apply only to KH; SwiftUI controls its own geometry. Renderer and
density order alternate between repetitions. Build/install the example first.
"""
import argparse
import subprocess
import sys
from pathlib import Path


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--device', required=True)
    parser.add_argument('--output', type=Path, default=Path('Documentation/Benchmarks/Geometry/raw'))
    parser.add_argument('--subdivisions', default='4,8,12,16,24,32,48,96')
    parser.add_argument('--repeats', type=int, default=3)
    parser.add_argument('--seconds', type=float, default=8)
    args = parser.parse_args()
    levels = [int(n) for n in args.subdivisions.split(',')]
    if any(n < 2 or n > 128 for n in levels) or len(levels) != len(set(levels)):
        parser.error('Choose distinct subdivisions in 2...128')
    script = Path(__file__).with_name('run_benchmarks.py')
    for repetition in range(1, args.repeats + 1):
        cases = [('kh', n) for n in levels] + [('swiftui', 48)]
        if repetition % 2 == 0:
            cases.reverse()
        for renderer, subdivisions in cases:
            subprocess.run([sys.executable, str(script), '--device', args.device,
                            '--output', str(args.output / (f'n{subdivisions}' if renderer == 'kh' else 'swiftui')),
                            '--counts', '60', '--meshes', 'organic', '--renderers', renderer,
                            '--width', '152', '--height', '88', '--fps', '120', '--random-seed', '42',
                            '--subdivisions', str(subdivisions), '--seconds', str(args.seconds),
                            '--repeats', '1', '--start-repetition', str(repetition)], check=True)


if __name__ == '__main__':
    main()
