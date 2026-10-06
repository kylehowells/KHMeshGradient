#!/usr/bin/env python3
"""Summarize fresh-process trials and plot CPU, memory, and update cadence.

The comparison uses whole-app process CPU, not the duration of a SwiftUI setter.
CADisplayLink intervals are labelled callback cadence, not GPU render duration.
"""
import argparse
import collections
import csv
import json
import statistics
from pathlib import Path

import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import numpy as np


def percentile(values, q):
    return float(np.percentile(values, q)) if values else None


def measure(data):
    phases = {p['name']: p for p in data['phases']}
    active, idle, baseline = phases['active'], phases['idle-before'], phases['baseline']
    duration = active['end']['wallTime'] - active['start']['wallTime']
    cpu = active['end']['cpuSeconds'] - active['start']['cpuSeconds']
    idle_duration = idle['end']['wallTime'] - idle['start']['wallTime']
    idle_cpu = idle['end']['cpuSeconds'] - idle['start']['cpuSeconds']
    footprint = statistics.mean(x['physicalFootprintBytes'] for x in active['memorySamples']) / 2**20
    baseline_footprint = statistics.mean(x['physicalFootprintBytes'] for x in baseline['memorySamples']) / 2**20
    metal = active['metalStatistics']
    cpu_frames = sum(x['cpuFrameCount'] for x in metal)
    gpu_frames = sum(x['gpuFrameCount'] for x in metal)
    presented_intervals = sum(x['presentationIntervalCount'] for x in metal)
    presented_seconds = sum(x['presentationIntervalSeconds'] for x in metal)
    updates = active['updateCount']
    idle_after = phases['idle-after']
    return {
        'runID': data['runID'], 'renderer': data['renderer'], 'mesh': data['mesh'], 'count': data['count'],
        'width': data['viewWidthPoints'], 'height': data['viewHeightPoints'], 'requestedFPS': data['requestedFPS'],
        'cpu_ms_per_update': cpu * 1000 / updates,
        'extra_cpu_ms_per_update_over_idle': (cpu - idle_cpu / idle_duration * duration) * 1000 / updates,
        'cpu_percent_one_core': cpu / duration * 100,
        'setter_mean_ms': statistics.mean(active['setterDurationsMS']),
        'callback_fps': updates / duration,
        'callback_p95_ms': percentile(active['callbackIntervalsMS'], 95),
        'callback_p99_ms': percentile(active['callbackIntervalsMS'], 99),
        'missed_requested_slots_percent': active['missedRequestedUpdateSlots'] / (active['missedRequestedUpdateSlots'] + active['tickCount']) * 100,
        'footprint_mb': footprint, 'baseline_footprint_mb': baseline_footprint,
        'incremental_footprint_mb': footprint - baseline_footprint,
        'peak_footprint_mb': max(x['physicalFootprintBytes'] for x in active['memorySamples']) / 2**20,
        'resident_mb': statistics.mean(x['residentBytes'] for x in active['memorySamples']) / 2**20,
        'average_extra_footprint_mb_per_view': (footprint - baseline_footprint) / data['count'],
        'construction_wall_ms': data['constructionWallSeconds'] * 1000,
        'idle_before_cpu_percent': idle_cpu / idle_duration * 100,
        'idle_after_cpu_percent': (idle_after['end']['cpuSeconds'] - idle_after['start']['cpuSeconds']) / (idle_after['end']['wallTime'] - idle_after['start']['wallTime']) * 100,
        'idle_before_footprint_mb': statistics.mean(x['physicalFootprintBytes'] for x in idle['memorySamples']) / 2**20,
        'idle_after_footprint_mb': statistics.mean(x['physicalFootprintBytes'] for x in phases['idle-after']['memorySamples']) / 2**20,
        'kh_cpu_wall_ms_per_mesh_draw': sum(x['cpuFrameSeconds'] for x in metal) * 1000 / cpu_frames if cpu_frames else None,
        'kh_gpu_ms_per_mesh_draw': sum(x['gpuFrameSeconds'] for x in metal) * 1000 / gpu_frames if gpu_frames else None,
        'kh_gpu_command_interval_sum_ms_per_update': sum(x['gpuFrameSeconds'] for x in metal) * 1000 / updates if gpu_frames else None,
        'kh_snapshot_ms_per_mesh_draw': sum(x['snapshotSeconds'] for x in metal) * 1000 / cpu_frames if cpu_frames else None,
        'kh_encoding_ms_per_mesh_draw': sum(x['encodingSeconds'] for x in metal) * 1000 / cpu_frames if cpu_frames else None,
        'kh_scheduling_wait_ms_per_mesh_draw': sum(x['schedulingWaitSeconds'] for x in metal) * 1000 / cpu_frames if cpu_frames else None,
        'kh_drawable_wait_ms_per_mesh_draw': sum(x['drawableWaitSeconds'] for x in metal) * 1000 / cpu_frames if cpu_frames else None,
        'kh_gpu_samples': gpu_frames,
        'kh_presented_fps_per_view': presented_intervals / presented_seconds if presented_seconds else None,
        'kh_submissions_per_update': active['metalSubmissions'] / updates if metal else None,
        'idle_after_metal_submissions': phases['idle-after']['metalSubmissions'],
        'gpu_errors': sum(x['gpuErrorCount'] for x in metal),
        'thermal_max': max(x['thermalState'] for p in phases.values() for x in p['memorySamples']),
        'low_power': any(x['lowPowerMode'] for p in phases.values() for x in p['memorySamples']),
        'all_visible': data['allMeshesVisible'], 'interruptions': data['interruptions'],
        'instrumented': data['metalStatisticsEnabled'], 'build': data['build'],
        'source_sha256': data.get('sourceTreeSHA256'), 'executable_sha256': data.get('measuredExecutableSHA256'),
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--raw', type=Path, default=Path('Documentation/Benchmarks/raw'))
    parser.add_argument('--output', type=Path, default=Path('Documentation/Benchmarks'))
    args = parser.parse_args()
    runs = [measure(json.loads(p.read_text())) for p in sorted(args.raw.glob('*.json'))]
    if not runs:
        raise SystemExit('No runs found')
    groups = collections.defaultdict(list)
    for r in runs:
        groups[(r['width'], r['height'], r['mesh'], r['count'], r['renderer'], r['requestedFPS'], r['instrumented'])].append(r)
    group_summaries = []
    for key, values in sorted(groups.items()):
        summary = {k: values[0][k] for k in ('width', 'height', 'mesh', 'count', 'renderer', 'requestedFPS', 'instrumented')}
        summary['runs'] = len(values)
        metrics = {}
        for k, v in values[0].items():
            if isinstance(v, (float, int)) and k not in summary and not isinstance(v, bool):
                samples = [r[k] for r in values if r[k] is not None]
                mean = statistics.mean(samples)
                sd = statistics.stdev(samples) if len(samples) > 1 else 0
                metrics[k] = {'mean': mean, 'sd': sd, 'cv_percent': sd / abs(mean) * 100 if mean else 0,
                              'minimum': min(samples), 'maximum': max(samples)}
        summary['metrics'] = metrics
        summary['valid_environment'] = all(r['all_visible'] and not r['interruptions'] and not r['low_power'] and r['thermal_max'] == 0 and r['build'] == 'Release' for r in values)
        group_summaries.append(summary)
    args.output.mkdir(parents=True, exist_ok=True)
    (args.output / 'summary.json').write_text(json.dumps({'runs': runs, 'groups': group_summaries}, indent=2) + '\n')
    with (args.output / 'runs.csv').open('w', newline='') as output:
        writer = csv.DictWriter(output, fieldnames=list(runs[0]), lineterminator='\n')
        writer.writeheader(); writer.writerows(runs)
    # Standard surfaces and high-count surfaces have separate panels/series.
    series = sorted({(r['width'], r['height'], r['mesh']) for r in runs})
    fig, axes = plt.subplots(len(series), 3, figsize=(13, 3.5 * len(series)), squeeze=False)
    colors = {'kh': '#7260d3', 'swiftui': '#008d91'}
    labels = {'kh': 'KHMeshGradientView', 'swiftui': 'SwiftUI MeshGradient'}
    for row, (width, height, mesh) in enumerate(series):
        for renderer in ('kh', 'swiftui'):
            selected = sorted([g for g in group_summaries if (g['width'], g['height'], g['mesh'], g['renderer']) == (width, height, mesh, renderer) and g['instrumented']], key=lambda g: g['count'])
            if not selected:
                selected = sorted([g for g in group_summaries if (g['width'], g['height'], g['mesh'], g['renderer']) == (width, height, mesh, renderer)], key=lambda g: g['count'])
            if not selected:
                continue
            xs = [g['count'] for g in selected]
            for col, metric, label in [(0, 'cpu_ms_per_update', 'Whole-app CPU / update (ms)'),
                                      (1, 'incremental_footprint_mb', 'Extra app footprint over baseline (MiB)'),
                                      (2, 'callback_fps', 'Actual mesh update callbacks / second')]:
                ys = [g['metrics'][metric]['mean'] for g in selected]
                errors = [g['metrics'][metric]['sd'] for g in selected]
                axes[row, col].errorbar(xs, ys, yerr=errors, marker='o', capsize=4, color=colors[renderer], label=labels[renderer])
                axes[row, col].set_ylabel(label)
                axes[row, col].set_xlabel('Visible mesh views')
                axes[row, col].grid(alpha=.2)
        axes[row, 0].set_title(f'{mesh} · {int(width)} × {int(height)} pt each')
        axes[row, 2].axhline(runs[0]['requestedFPS'], color='#777', ls='--', lw=1, label='Requested rate')
        counts = sorted({r['count'] for r in runs if (r['width'], r['height'], r['mesh']) == (width, height, mesh)})
        for ax in axes[row]:
            ax.set_ylim(bottom=0)
            ax.set_xticks(counts)
            ax.legend(fontsize=8)
        axes[row, 2].set_ylim(0, runs[0]['requestedFPS'] * 1.08)
    fig.suptitle('Physical M1 iPad Pro · iPadOS 18.6 · Release build\nMean ± sample standard deviation across fresh launches', fontsize=14)
    fig.tight_layout(rect=(0, 0, 1, .94))
    fig.savefig(args.output / 'performance-comparison.png', dpi=180)
    plt.close(fig)
    for g in group_summaries:
        m = g['metrics']
        print(f"{g['width']}x{g['height']} {g['mesh']:7} {g['count']:2} {g['renderer']:7} n={g['runs']} "
              f"CPU={m['cpu_ms_per_update']['mean']:.3f}ms CV={m['cpu_ms_per_update']['cv_percent']:.1f}% "
              f"extra={m['incremental_footprint_mb']['mean']:.2f}MiB FPS={m['callback_fps']['mean']:.2f} valid={g['valid_environment']}")


if __name__ == '__main__':
    main()
