#!/usr/bin/env python3
"""Validate and summarize the repeated geometry sweep and separate GPU profiles."""
import collections
import csv
import json
from pathlib import Path
import statistics

import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt

from analyze_benchmarks import measure

ROOT = Path(__file__).resolve().parent.parent / 'Documentation/Benchmarks/Geometry'


def distribution(values):
    return {'mean': statistics.mean(values), 'sd': statistics.stdev(values),
            'minimum': min(values), 'maximum': max(values)}


def main():
    groups = collections.defaultdict(list)
    runs = []
    hashes = collections.defaultdict(set)
    for path in sorted((ROOT / 'raw').glob('*/*.json')):
        data = json.loads(path.read_text())
        row = measure(data)
        row['subdivisions'] = data['subdivisions'] if data['renderer'] == 'kh' else None
        row['gpu_batch_envelope_ms'] = row['kh_gpu_equal_share_ms_per_mesh_draw'] * 60 if data['renderer'] == 'kh' else None
        assert row['build'] == 'Release' and not data['isSimulator']
        assert row['all_visible'] and not row['interruptions'] and not row['gpu_errors']
        assert row['thermal_max'] == 0 and not row['low_power']
        assert data['count'] == data['uniqueFixtureCount'] == 60 and data['randomSeed'] == '42'
        assert data['viewWidthPoints'] == 152 and data['viewHeightPoints'] == 88 and data['requestedFPS'] == 120
        if data['renderer'] == 'kh':
            assert row['idle_after_metal_submissions'] == 0
            assert 59 <= row['kh_submissions_per_update'] <= 61
            assert .98 <= row['kh_command_buffers_per_update'] <= 1.02
            assert 7.8 <= row['kh_render_passes_per_update'] <= 8.2
            active = next(p for p in data['phases'] if p['name'] == 'active')
            assert all(s['cpuFrameCount'] >= active['updateCount'] * .98 for s in active['metalStatistics'])
        for key in ['fixtureSHA256', 'sourceTreeSHA256', 'measuredExecutableSHA256', 'model', 'os']:
            hashes[key].add(data[key])
        groups[(data['renderer'], row['subdivisions'])].append(row)
        runs.append(row)
    assert len(runs) == 27 and all(len(v) == 3 for v in groups.values())
    assert all(len(v) == 1 for v in hashes.values()), hashes
    keys = ['cpu_ms_per_update', 'incremental_footprint_mb', 'callback_fps',
            'kh_presented_fps_per_view', 'gpu_batch_envelope_ms']
    summaries = []
    for (renderer, n), values in sorted(groups.items(), key=lambda pair: (pair[0][0], pair[0][1] or 0)):
        summaries.append({'renderer': renderer, 'subdivisions': n, 'runs': 3,
                          'metrics': {key: distribution([r[key] for r in values]) for key in keys if values[0][key] is not None}})
    profile_groups = collections.defaultdict(list)
    for path in sorted((ROOT / 'gpu').glob('geometry-*.json')):
        data = json.loads(path.read_text())
        assert data['fixtureSHA256'] in hashes['fixtureSHA256']
        assert data['measuredExecutableSHA256'] in hashes['measuredExecutableSHA256']
        assert data['completeFractionOfObserved'] == 1 and data['idleBeforeObservedAppCommandBuffers'] == 0
        assert data['thermalMax'] == 0 and not data['lowPowerMode'] and not data['interruptions']
        assert data['allMeshesVisible'] and .98 <= data['observedCommandBuffersPerUpdate'] <= 1.02
        profile_groups[data['renderer']].append(data)
    profiles = []
    for renderer, values in sorted(profile_groups.items()):
        assert len(values) == 3
        profiles.append({'renderer': renderer, 'runs': 3,
                         'gpu_envelope_ms': distribution([r['gpuEnvelopeMeanMS'] for r in values]),
                         'gpu_active_union_ms': distribution([r['observedGPUActiveUnionMSPerUpdate'] for r in values]),
                         'stages': {stage: distribution([r['observedGPUStageActiveUnionMSPerUpdate'][stage] for r in values])
                                    for stage in ['Vertex', 'Fragment']}})
    result = {'groups': summaries, 'profiles': profiles, 'hashes': {k: list(v)[0] for k, v in hashes.items()}, 'runs': runs}
    (ROOT / 'summary.json').write_text(json.dumps(result, indent=2) + '\n')
    with (ROOT / 'runs.csv').open('w', newline='') as output:
        writer = csv.DictWriter(output, fieldnames=list(runs[0]), lineterminator='\n')
        writer.writeheader()
        writer.writerows(runs)
    lines = ['# Repeated geometry-resolution measurements', '',
             'Physical M1 iPad, iPadOS 18.6, Release; 60 distinct seed-42 organic gradients, 152×88 pt each, scale 2, requested 120 Hz. Three fresh processes per row. All runs retained; nominal thermal state, Low Power Mode off, no interruptions, all views visible, no GPU errors. KH idle-after submits zero frames.', '',
             '| Renderer / subdivisions | CPU ms/update | Extra MiB | Updates/s | KH presentation/s | KH GPU batch envelope ms |',
             '| --- | ---: | ---: | ---: | ---: | ---: |']
    def cell(group, key):
        d = group['metrics'].get(key)
        return f'{d["mean"]:.2f} ± {d["sd"]:.2f}' if d else '—'
    for group in summaries:
        label = f'KH / {group["subdivisions"]}' if group['renderer'] == 'kh' else 'SwiftUI / managed'
        lines.append('| ' + ' | '.join([label] + [cell(group, k) for k in keys[:3]] + [cell(group, keys[3]), cell(group, keys[4])]) + ' |')
    lines += ['', 'CPU is consumed whole-process time, not setter latency. GPU diagnostics sum equal shares of a completed shared command buffer; these are grid envelopes, not isolated per-view costs. Callback rate does not establish SwiftUI presentation cadence. The 96-subdivision setting falls below 120 Hz, so its CPU/update value describes a different throughput.', '',
              '## Separate GPU profiles', '', 'CPU/cadence under profiling are excluded above. Both renderers use the same all-process Metal System Trace mode, filtered to app depth-zero Active stages. Stages overlap; their times cannot be added.', '',
              '| Renderer | Mean command envelope ms | Active union ms/update | Vertex active ms/update | Fragment active ms/update |',
              '| --- | ---: | ---: | ---: | ---: |']
    for group in profiles:
        d = [group['gpu_envelope_ms'], group['gpu_active_union_ms'], group['stages']['Vertex'], group['stages']['Fragment']]
        lines.append('| ' + group['renderer'] + (' / 16' if group['renderer'] == 'kh' else '') + ' | ' +
                     ' | '.join(f'{v["mean"]:.3f} ± {v["sd"]:.3f}' for v in d) + ' |')
    lines += ['', 'Each profile covers five seconds of motion. Frequency and capture overhead can affect GPU intervals; this is one device/workload, not universal parity. Raw traces/XML remain in ignored DerivedData. Every successful profile has complete Vertex/Fragment pairs, one observed app command buffer per update, zero idle-before buffers, and the matching input hash.', '']
    (ROOT / 'results.md').write_text('\n'.join(lines))
    kh = [g for g in summaries if g['renderer'] == 'kh']
    levels = [g['subdivisions'] for g in kh]
    fig, axes = plt.subplots(1, 3, figsize=(13, 4.2), layout='constrained')
    for ax, key, title, unit in zip(axes, ['gpu_batch_envelope_ms', 'incremental_footprint_mb', 'callback_fps'],
                                  ['KH GPU grid envelope', 'Extra app footprint', 'Update cadence'], ['ms', 'MiB', 'updates/s']):
        ax.errorbar(levels, [g['metrics'][key]['mean'] for g in kh], yerr=[g['metrics'][key]['sd'] for g in kh], marker='o', capsize=3)
        ax.set_xscale('log', base=2)
        ax.set_xticks(levels, labels=[str(n) for n in levels])
        ax.set_title(title)
        ax.set_xlabel('Subdivisions per patch axis')
        ax.set_ylabel(unit)
        ax.grid(alpha=.2)
    axes[2].axhline(120, linestyle='--', color='#8899aa', alpha=.6)
    axes[2].plot(levels, [g['metrics']['kh_presented_fps_per_view']['mean'] for g in kh], marker='s', color='#e08935', label='KH drawable presentation')
    axes[2].lines[0].set_label('Update callbacks')
    axes[2].set_ylabel('frames or updates/s')
    axes[2].legend(fontsize=8)
    fig.suptitle('60 distinct gradients · M1 iPad · 3 Release trials per setting')
    fig.savefig(ROOT / 'performance-by-resolution.png', dpi=150)
    plt.close(fig)
    print('\n'.join(lines))


if __name__ == '__main__':
    main()
