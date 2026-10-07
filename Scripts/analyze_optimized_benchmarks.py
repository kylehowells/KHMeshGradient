#!/usr/bin/env python3
"""Validate and compare original, command-batched, and MRT Release trials."""
import csv
import json
import statistics
from pathlib import Path

import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from analyze_benchmarks import measure

ROOT = Path(__file__).resolve().parent.parent / 'Documentation/Benchmarks/Optimized'
STAGES = [('Original', 'before/raw'), ('Command batching', 'after/raw'),
          ('Command batching, diagnostics off', 'after/controls'),
          ('Optimized MRT', 'final/raw'), ('Optimized MRT, diagnostics off', 'final/controls')]
METRICS = ['cpu_ms_per_update', 'incremental_footprint_mb', 'footprint_mb', 'callback_fps',
           'setter_mean_ms', 'callback_p95_ms', 'kh_command_buffers_per_update', 'kh_render_passes_per_update',
           'kh_gpu_command_interval_sum_ms_per_update', 'kh_presented_fps_per_view', 'idle_after_metal_submissions']


def main():
    rows, groups, hashes = [], [], {}
    fixtures = None
    for stage, folder in STAGES:
        raw = [json.loads(p.read_text()) for p in sorted((ROOT / folder).glob('*.json'))]
        if not raw:
            continue
        hashes[stage] = {'executables': sorted({d['measuredExecutableSHA256'] for d in raw}),
                         'sources': sorted({d['sourceTreeSHA256'] for d in raw})}
        assert len(hashes[stage]['executables']) == len(hashes[stage]['sources']) == 1
        for d in raw:
            r = measure(d)
            assert r['all_visible'] and not r['interruptions'] and not r['low_power'] and r['thermal_max'] == 0
            assert r['build'] == 'Release' and not d['isSimulator'] and not r['gpu_errors']
            assert d['count'] == 60 and d['uniqueFixtureCount'] == 60 and d['randomSeed'] == '42'
            assert d['requestedFPS'] == 120 and d['subdivisions'] == 48
            assert (d['viewWidthPoints'], d['viewHeightPoints'], d['screenWidthPoints'], d['screenHeightPoints'], d['displayScale']) == (152, 88, 1590, 1192, 2)
            assert d['os'] == '18.6' and d['model'] == 'iPad13,11'
            fixture = (d['fixtureSHA256'], d['perViewFixtureSHA256'], d['fixtureInputs'])
            if fixtures is None:
                fixtures = fixture
            assert fixture == fixtures
            if r['renderer'] == 'kh':
                active = next(p for p in d['phases'] if p['name'] == 'active')
                assert abs(active['metalSubmissions'] / active['updateCount'] - 60) < .1
                assert r['idle_after_metal_submissions'] == 0
                if r['instrumented']:
                    assert all(s['cpuFrameCount'] > active['updateCount'] * .95 for s in active['metalStatistics'])
            r.update(stage=stage, fixture_sha256=d['fixtureSHA256'])
            rows.append(r)
        for renderer in ('kh', 'swiftui'):
            selected = [r for r in rows if r['stage'] == stage and r['renderer'] == renderer]
            if not selected:
                continue
            assert len(selected) == 3
            metrics = {}
            for name in METRICS:
                values = [r[name] for r in selected if r[name] is not None]
                if values:
                    metrics[name] = {'mean': statistics.mean(values), 'sd': statistics.stdev(values),
                                     'minimum': min(values), 'maximum': max(values)}
            groups.append({'stage': stage, 'renderer': renderer, 'runs': len(selected), 'metrics': metrics})
    result = {'groups': groups, 'runs': rows, 'buildHashes': hashes, 'fixtureSHA256': fixtures[0]}
    (ROOT / 'summary.json').write_text(json.dumps(result, indent=2) + '\n')
    with (ROOT / 'runs.csv').open('w', newline='') as output:
        writer = csv.DictWriter(output, fieldnames=list(rows[0]), lineterminator='\n')
        writer.writeheader(); writer.writerows(rows)
    lines = ['# Optimization results', '',
             'Physical M1 iPad Pro, iPadOS 18.6, Release. Three fresh-process trials per row; 60 unique 4×4 gradients, seed 42, 152×88 pt each, scale 2, requested 120 Hz. Identical palettes, geometry, trajectories, viewport, and 48 subdivisions. Mean ± sample standard deviation.', '',
             '| Version | Renderer | CPU ms/update | Extra app MiB | Updates/s | Presented/s per view | Command buffers/update | Render passes/update |',
             '| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |']
    def value(g, name, digits=2):
        m = g['metrics'].get(name)
        return f'{m["mean"]:.{digits}f} ± {m["sd"]:.{digits}f}' if m else '—'
    for g in groups:
        lines.append(f'| {g["stage"]} | {g["renderer"]} | {value(g,"cpu_ms_per_update")} | {value(g,"incremental_footprint_mb")} | {value(g,"callback_fps",1)} | {value(g,"kh_presented_fps_per_view",1)} | {value(g,"kh_command_buffers_per_update")} | {value(g,"kh_render_passes_per_update")} |')
    lines += ['', 'CPU is whole-process consumed CPU time per update, not main-thread latency. Memory is app physical footprint above each fresh blank baseline. Update callbacks do not establish SwiftUI presentation cadence. KH presentation rates come from drawable timestamps. CPU/memory trials run without Instruments. GPU diagnostic times in the raw files allocate each completed command-buffer envelope equally among its participating views; they are not isolated per-mesh GPU timings. Original per-mesh command envelopes cannot be summed and treated as an overlap-free scene GPU measurement.', '',
              'All published trials have nominal thermal state, Low Power Mode off, no active-app interruptions, no GPU errors, and all meshes visible. Every KH idle-after phase submits zero frames. Build and fixture hashes are preserved in summary.json and every raw trial.', '']
    (ROOT / 'results.md').write_text('\n'.join(lines))
    candidates = [('Original','kh','Before'),('Command batching','kh','One buffer'),('Optimized MRT','kh','MRT'),('Optimized MRT','swiftui','SwiftUI')]
    selected = [(label, next((g for g in groups if g['stage'] == stage and g['renderer'] == renderer), None)) for stage, renderer, label in candidates]
    selected = [(label,g) for label,g in selected if g]
    fig, axes = plt.subplots(1, 3, figsize=(12, 4.5))
    for ax, metric, title in zip(axes, ['cpu_ms_per_update','incremental_footprint_mb','callback_fps'], ['App CPU / update (ms)','Extra app physical footprint (MiB)','Update callbacks / second']):
        ax.bar([label for label,g in selected], [g['metrics'][metric]['mean'] for label,g in selected],
               yerr=[g['metrics'][metric]['sd'] for label,g in selected], capsize=4, color=['#8d8e9a','#aaa0de','#7260d3','#008d91'][:len(selected)])
        ax.set_ylabel(title); ax.grid(axis='y',alpha=.2)
    axes[2].axhline(120,color='#777',ls='--',lw=1); axes[2].set_ylim(0,130)
    fig.suptitle('60 distinct 4×4 gradients · 152×88 pt · 120 Hz request\nM1 iPad Pro / iPadOS 18.6 · Release · 3 fresh trials per row · unchanged mesh quality')
    fig.tight_layout(rect=(0,0,1,.90)); fig.savefig(ROOT/'optimization-comparison.png',dpi=180); plt.close(fig)
    print('\n'.join(lines[:14]))


if __name__ == '__main__': main()
