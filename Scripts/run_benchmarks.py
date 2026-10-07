#!/usr/bin/env python3
"""Run paired, fresh-process benchmarks on a connected physical iPad.

Build/install the Release example first. Device identifiers are CLI inputs only;
they are not copied to published measurement JSON. No instrumented trace is run
during the primary measurement matrix.
"""
import argparse
import datetime
import hashlib
import json
import statistics
import subprocess
import tempfile
import time
import uuid
from pathlib import Path

BUNDLE = 'com.kylehowells.KHMeshGradientExample'


def command(args, timeout=30):
    return subprocess.run(['xcrun', 'devicectl', *args], text=True, capture_output=True, timeout=timeout)


def percentile(values, q):
    return sorted(values)[int((len(values) - 1) * q)] if values else 0


def summary(data):
    active = next(p for p in data['phases'] if p['name'] == 'active')
    idle = next(p for p in data['phases'] if p['name'] == 'idle-before')
    baseline = next(p for p in data['phases'] if p['name'] == 'baseline')
    seconds = active['end']['wallTime'] - active['start']['wallTime']
    cpu = active['end']['cpuSeconds'] - active['start']['cpuSeconds']
    footprint = statistics.mean(p['physicalFootprintBytes'] for p in active['memorySamples']) / 2**20
    baseline_footprint = statistics.mean(p['physicalFootprintBytes'] for p in baseline['memorySamples']) / 2**20
    metal = active['metalStatistics']
    gpu_count = sum(s['gpuFrameCount'] for s in metal)
    gpu_ms = sum(s['gpuFrameSeconds'] for s in metal) * 1000 / gpu_count if gpu_count else None
    return {
        'cpu_ms_per_update': cpu * 1000 / max(1, active['updateCount']),
        'cpu_percent_one_core': cpu / seconds * 100,
        'callback_fps': active['updateCount'] / seconds,
        'callback_p95_ms': percentile(active['callbackIntervalsMS'], .95),
        'footprint_mb': footprint, 'incremental_footprint_mb': footprint - baseline_footprint,
        'kh_gpu_ms_per_mesh': gpu_ms if data.get('metalGPUTimeAllocation') != 'equal-share-of-batch' else None,
        'kh_gpu_equal_share_ms_per_mesh': gpu_ms if data.get('metalGPUTimeAllocation') == 'equal-share-of-batch' else None,
        'thermal_max': max(s['thermalState'] for p in data['phases'] for s in p['memorySamples']),
        'idle_cpu_percent': (idle['end']['cpuSeconds'] - idle['start']['cpuSeconds']) / (idle['end']['wallTime'] - idle['start']['wallTime']) * 100,
    }


def run_case(args, renderer, count, mesh, repetition):
    suffix = '-uninstrumented' if args.no_metal_statistics else ''
    if args.random_seed is not None:
        suffix += f'-seed{args.random_seed}'
    run_id = f'{args.fps}hz-{args.width}x{args.height}-{mesh}-{count}-{renderer}-r{repetition}{suffix}'
    destination = args.output / f'{run_id}.json'
    if destination.exists() and not args.overwrite:
        data = json.loads(destination.read_text())
        print(f'REUSE {run_id} {json.dumps(summary(data))}', flush=True)
        return data
    launch_args = [
        '--benchmark', renderer, '--bench-count', str(count), '--bench-mesh', mesh,
        '--bench-id', run_id, '--bench-fps', str(args.fps), '--bench-seconds', str(args.seconds),
        '--bench-width', str(args.width), '--bench-height', str(args.height),
    ]
    nonce = str(uuid.uuid4())
    launch_args.extend(['--bench-token', nonce])
    if args.no_metal_statistics:
        launch_args.append('--bench-no-metal-statistics')
    if args.random_seed is not None:
        launch_args.extend(['--bench-random-seed', str(args.random_seed)])
    with tempfile.TemporaryDirectory(prefix='khmesh-launch-') as temporary:
        result_path = Path(temporary) / 'launch.json'
        launched = command(['device', 'process', 'launch', '--device', args.device,
                            '--terminate-existing', '--json-output', str(result_path), BUNDLE, *launch_args])
        if launched.returncode:
            raise RuntimeError(launched.stdout + launched.stderr)
        print(f'START {run_id}', flush=True)
    # The fixed phases total 12 seconds plus the requested active duration.
    deadline = time.monotonic() + args.seconds + 60
    time.sleep(args.seconds + 12.5)
    while time.monotonic() < deadline:
        copied = command(['device', 'copy', 'from', '--device', args.device,
                          '--domain-type', 'appDataContainer', '--domain-identifier', BUNDLE,
                          '--source', f'Documents/Benchmarks/{run_id}.json', '--destination', str(destination)])
        if copied.returncode == 0 and destination.exists():
            data = json.loads(destination.read_text())
            if data.get('launchNonce') != nonce:
                time.sleep(2)
                continue
            data['measuredExecutableSHA256'] = args.executable_sha256
            data['sourceTreeSHA256'] = args.source_sha256
            data['capturedAtUTC'] = datetime.datetime.now(datetime.timezone.utc).isoformat()
            destination.write_text(json.dumps(data, indent=2) + '\n')
            if data['count'] != count or data['renderer'] != renderer or data['mesh'] != mesh:
                raise RuntimeError(f'Benchmark configuration differs from request: {run_id}')
            if args.random_seed is not None and (data.get('randomSeed') != str(args.random_seed) or data.get('uniqueFixtureCount') != count):
                raise RuntimeError(f'Randomized fixture validation failed: {run_id}')
            if not data['allMeshesVisible'] or data['interruptions']:
                raise RuntimeError(f'Invalid run {run_id}: visibility={data["allMeshesVisible"]}, interruptions={data["interruptions"]}')
            print(f'DONE {run_id} {json.dumps(summary(data))}', flush=True)
            return data
        time.sleep(2)
    raise RuntimeError(f'Benchmark did not finish: {run_id}\n{copied.stderr}')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--device', required=True)
    parser.add_argument('--output', type=Path, default=Path('Documentation/Benchmarks/raw'))
    parser.add_argument('--counts', default='1,5,15')
    parser.add_argument('--meshes', default='rainbow,organic')
    parser.add_argument('--renderers', default='kh,swiftui')
    parser.add_argument('--repeats', type=int, default=3)
    parser.add_argument('--start-repetition', type=int, default=1)
    parser.add_argument('--fps', type=int, default=60)
    parser.add_argument('--width', type=int, default=320)
    parser.add_argument('--height', type=int, default=200)
    parser.add_argument('--seconds', type=float, default=8)
    parser.add_argument('--no-metal-statistics', action='store_true')
    parser.add_argument('--random-seed', type=int)
    parser.add_argument('--overwrite', action='store_true')
    parser.add_argument('--suite', choices=['primary120'])
    args = parser.parse_args()
    if args.random_seed is not None and not 0 <= args.random_seed < 2**64:
        parser.error('--random-seed must be an unsigned 64-bit integer')
    root = Path(__file__).resolve().parent.parent
    executable = root / 'DerivedData/BenchmarkDevice/Build/Products/Release-iphoneos/KHMeshGradientExample.app/KHMeshGradientExample'
    args.executable_sha256 = hashlib.sha256(executable.read_bytes()).hexdigest()
    source = hashlib.sha256()
    for path in sorted([*root.glob('Sources/**/*.swift'), *root.glob('Sources/**/*.metal'), *root.glob('Example/Sources/*.swift')]):
        source.update(str(path.relative_to(root)).encode())
        source.update(path.read_bytes())
    args.source_sha256 = source.hexdigest()
    args.output.mkdir(parents=True, exist_ok=True)
    counts = [int(c) for c in args.counts.split(',')]
    if not counts or any(c < 1 or c > 64 for c in counts):
        parser.error('Each view count must be between 1 and 64 (the example limit)')
    meshes = args.meshes.split(',')
    renderers = args.renderers.split(',')
    if args.suite:
        args.fps = 120
        cases = [(320, 200, m, c) for m in ('rainbow', 'organic') for c in (5, 15)]
        cases += [(152, 88, 'organic', c) for c in (15, 30, 60)]
    else:
        cases = [(args.width, args.height, m, c) for m in meshes for c in counts]
    for repetition in range(args.start_repetition, args.start_repetition + args.repeats):
        ordered_cases = cases if repetition % 2 else list(reversed(cases))
        ordered_renderers = renderers if repetition % 2 else list(reversed(renderers))
        for width, height, mesh, count in ordered_cases:
            args.width, args.height = width, height
            for renderer in ordered_renderers:
                run_case(args, renderer, count, mesh, repetition)


if __name__ == '__main__':
    main()
