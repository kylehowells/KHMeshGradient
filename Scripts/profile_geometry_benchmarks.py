#!/usr/bin/env python3
"""Separate, repeatable app-only Metal System Trace comparison.

Build/install Release first. Raw traces/XML and device identifiers remain in
ignored DerivedData. Only sanitized aggregate results go into Documentation.
Performance under profiling is excluded from the primary unprofiled sweep.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import time
import uuid

from run_benchmarks import BUNDLE


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--device', required=True, help='CoreDevice identifier for devicectl')
    parser.add_argument('--trace-device', required=True, help='Device UDID accepted by xctrace')
    parser.add_argument('--subdivisions', type=int, default=16)
    parser.add_argument('--repeats', type=int, default=3)
    parser.add_argument('--output', type=Path, default=Path('Documentation/Benchmarks/Geometry/gpu'))
    parser.add_argument('--raw', type=Path, default=Path('DerivedData/GeometryProfiles'))
    args = parser.parse_args()
    args.raw.mkdir(parents=True, exist_ok=True)
    args.output.mkdir(parents=True, exist_ok=True)
    root = Path(__file__).resolve().parent.parent
    executable = root / 'DerivedData/BenchmarkDevice/Build/Products/Release-iphoneos/KHMeshGradientExample.app/KHMeshGradientExample'
    executable_hash = hashlib.sha256(executable.read_bytes()).hexdigest()
    for repetition in range(1, args.repeats + 1):
        renderers = ['kh', 'swiftui'] if repetition % 2 else ['swiftui', 'kh']
        for renderer in renderers:
            id = f'geometry-{renderer}-n{args.subdivisions}-r{repetition}'
            result = args.output / f'{id}.json'
            if result.exists():
                print('REUSE', id, flush=True)
                continue
            nonce = str(uuid.uuid4())
            launch = ['xcrun', 'devicectl', 'device', 'process', 'launch', '--device', args.device,
                      '--terminate-existing', BUNDLE, '--benchmark', renderer, '--bench-id', id,
                      '--bench-token', nonce, '--bench-count', '60', '--bench-mesh', 'organic',
                      '--bench-width', '152', '--bench-height', '88', '--bench-fps', '120',
                      '--bench-seconds', '5', '--bench-delay', '12', '--bench-random-seed', '42',
                      '--bench-subdivisions', str(args.subdivisions)]
            subprocess.run(launch, check=True, capture_output=True, text=True)
            print('PROFILE_START', id, flush=True)
            trace = args.raw / f'{id}.trace'
            with (args.raw / f'{id}.record.log').open('w') as log:
                subprocess.run(['xcrun', 'xctrace', 'record', '--device', args.trace_device,
                                '--template', 'Metal System Trace', '--time-limit', '27s',
                                '--all-processes', '--output', str(trace), '--no-prompt'],
                               check=True, stdout=log, stderr=subprocess.STDOUT)
            run_path = args.raw / f'{id}.json'
            for attempt in range(15):
                copied = subprocess.run(['xcrun', 'devicectl', 'device', 'copy', 'from', '--device', args.device,
                                         '--domain-type', 'appDataContainer', '--domain-identifier', BUNDLE,
                                         '--source', f'Documents/Benchmarks/{id}.json', '--destination', str(run_path)],
                                        capture_output=True, text=True)
                if copied.returncode == 0 and run_path.exists():
                    data = json.loads(run_path.read_text())
                    if data.get('launchNonce') == nonce:
                        break
                time.sleep(1)
            else:
                raise RuntimeError('Missing fresh profile metadata: ' + id)
            data['measuredExecutableSHA256'] = executable_hash
            run_path.write_text(json.dumps(data, indent=2) + '\n')
            for table in ['time-info', 'metal-gpu-intervals']:
                with (args.raw / f'{id}-{table}.xml').open('w') as output:
                    subprocess.run(['xcrun', 'xctrace', 'export', '--input', str(trace),
                                    '--xpath', f'/trace-toc/run[@number="1"]/data/table[@schema="{table}"]'],
                                   check=True, stdout=output)
            subprocess.run(['python3', str(root / 'Scripts/analyze_gpu_trace.py'),
                            '--time', str(args.raw / f'{id}-time-info.xml'), '--gpu', str(args.raw / f'{id}-metal-gpu-intervals.xml'),
                            '--run', str(run_path), '--output', str(result)], check=True)
            summary = json.loads(result.read_text())
            if not data['allMeshesVisible'] or data['interruptions'] or summary['completeFractionOfObserved'] != 1:
                raise RuntimeError('Incomplete/invalid profile: ' + id)
            print('PROFILE_COMPLETE', id, flush=True)


if __name__ == '__main__':
    main()
