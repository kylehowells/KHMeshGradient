#!/usr/bin/env python3
"""Validate current adaptive renderer trials and preserve the fixed-48 baseline."""
import collections
import csv
import json
from pathlib import Path
import statistics

import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt

from analyze_benchmarks import measure

ROOT = Path(__file__).resolve().parent.parent / 'Documentation/Benchmarks/Adaptive'


def distribution(values):
    return {'mean': statistics.mean(values), 'sd': statistics.stdev(values) if len(values) > 1 else None,
            'minimum': min(values), 'maximum': max(values)}


def main():
    groups = collections.defaultdict(list)
    rows = []
    current_hashes = collections.defaultdict(set)
    fixtures = collections.defaultdict(set)
    sources = [(ROOT / 'raw', 'Adaptive'), (ROOT / 'large/raw', 'Adaptive'),
               (ROOT.parent / 'Geometry/raw/n48', 'Before')]
    for directory, stage in sources:
        for path in sorted(directory.glob('*.json')):
            data = json.loads(path.read_text())
            row = measure(data)
            row['stage'] = stage
            row['geometry'] = data['geometryResolutionScope']
            row['gpu_batch_envelope_ms'] = row['kh_gpu_equal_share_ms_per_mesh_draw'] * data['count'] if data['renderer'] == 'kh' else None
            active = next(p for p in data['phases'] if p['name'] == 'active')
            row['triangles_per_update'] = sum(s.get('triangleCount', 0) for s in active['metalStatistics']) / active['updateCount'] if stage == 'Adaptive' and data['renderer'] == 'kh' else None
            row['last_density_histogram'] = dict(collections.Counter(str(s['lastSubdivisionCount']) for s in active['metalStatistics'])) if stage == 'Adaptive' and data['renderer'] == 'kh' else None
            assert data['model'] == 'iPad13,11' and data['os'] == '18.6' and data['build'] == 'Release' and not data['isSimulator']
            assert row['all_visible'] and not row['interruptions'] and not row['gpu_errors'] and row['thermal_max'] == 0 and not row['low_power']
            assert data['uniqueFixtureCount'] == data['count'] and data['randomSeed'] == '42'
            fixtures[data['count']].add(data['fixtureSHA256'])
            if stage == 'Adaptive':
                assert data['subdivisions'] == 0
                for key in ['sourceTreeSHA256', 'measuredExecutableSHA256']:
                    current_hashes[key].add(data[key])
            if data['renderer'] == 'kh':
                assert row['idle_after_metal_submissions'] == 0
                assert .98 <= row['kh_submissions_per_update'] / data['count'] <= 1.02
                assert .98 <= row['kh_command_buffers_per_update'] <= 1.02
                expected_passes = (data['count'] + 7) // 8
                assert expected_passes * .98 <= row['kh_render_passes_per_update'] <= expected_passes * 1.02
                assert all(s['cpuFrameCount'] >= active['updateCount'] * .98 for s in active['metalStatistics'])
                if stage == 'Adaptive':
                    assert all(1 <= s['lastSubdivisionCount'] <= 128 for s in active['metalStatistics'])
                    assert row['triangles_per_update'] < data['count'] * 9 * 2 * 48 * 48
            groups[(data['count'], stage, data['renderer'])].append(row)
            rows.append(row)
    assert len(rows) == 15 and all(len(v) == 3 for v in groups.values())
    assert all(len(v) == 1 for v in current_hashes.values()), current_hashes
    assert all(len(v) == 1 for v in fixtures.values()), fixtures
    metrics = ['cpu_ms_per_update', 'incremental_footprint_mb', 'callback_fps', 'kh_presented_fps_per_view', 'gpu_batch_envelope_ms', 'triangles_per_update']
    summaries = []
    for (count, stage, renderer), values in sorted(groups.items()):
        summaries.append({'count': count, 'stage': stage, 'renderer': renderer, 'runs': 3,
                          'metrics': {key: distribution([r[key] for r in values]) for key in metrics if values[0][key] is not None}})
    profile_groups = collections.defaultdict(list)
    for path in sorted((ROOT / 'gpu').glob('geometry-*.json')):
        data = json.loads(path.read_text())
        assert data['measuredExecutableSHA256'] in current_hashes['measuredExecutableSHA256']
        assert data['fixtureSHA256'] in fixtures[60]
        assert data['completeFractionOfObserved'] == 1 and data['idleBeforeObservedAppCommandBuffers'] == 0
        assert data['thermalMax'] == 0 and not data['lowPowerMode'] and not data['interruptions'] and data['allMeshesVisible']
        assert .98 <= data['observedCommandBuffersPerUpdate'] <= 1.02
        profile_groups[data['renderer']].append(data)
    assert set(profile_groups) == {'kh', 'swiftui'}
    profiles = []
    for renderer, values in sorted(profile_groups.items()):
        profiles.append({'renderer': renderer, 'runs': len(values),
                         'gpu_envelope_ms': distribution([r['gpuEnvelopeMeanMS'] for r in values]),
                         'gpu_active_union_ms': distribution([r['observedGPUActiveUnionMSPerUpdate'] for r in values]),
                         'stages': {stage: distribution([r['observedGPUStageActiveUnionMSPerUpdate'][stage] for r in values]) for stage in ['Vertex', 'Fragment']}})
    summary = {'groups': summaries, 'profiles': profiles, 'currentHashes': {k: list(v)[0] for k, v in current_hashes.items()},
               'fixtureHashesByCount': {k: list(v)[0] for k, v in fixtures.items()}, 'runs': rows}
    (ROOT / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    with (ROOT / 'runs.csv').open('w', newline='') as output:
        writer = csv.DictWriter(output, fieldnames=list(rows[0]), lineterminator='\n')
        writer.writeheader(); writer.writerows(rows)
    lines = ['# Adaptive renderer measurements', '',
             'Three fresh Release processes per row, same M1 iPad/iPadOS 18.6, requested 120 Hz, distinct seed-42 meshes. Current KH and SwiftUI pairs use one executable. Before uses the preserved geometry-sweep fixed-48 executable; input hashes match the current 60-view case. All runs retained; no thermal/power/visibility/interruptions/GPU errors. KH idle-after submits zero frames.', '',
             '| Views / renderer | CPU ms/update | Extra MiB | Updates/s | KH presentation/s | KH GPU batch envelope ms |',
             '| --- | ---: | ---: | ---: | ---: | ---: |']
    for group in summaries:
        label = f'{group["count"]} / {group["stage"]} {group["renderer"]}'
        cells = []
        for key in metrics[:-1]:
            d = group['metrics'].get(key)
            cells.append(f'{d["mean"]:.2f} ± {d["sd"]:.2f}' if d else '—')
        lines.append('| ' + ' | '.join([label] + cells) + ' |')
    lines += ['', '60-view cells are 152×88 pt; 15-view cells are 320×200 pt, both at scale 2. CPU is whole-process consumed time; callbacks are not SwiftUI presentation proof. KH diagnostics allocate completed command-buffer envelopes across participating views; they are not isolated per-view costs. The compositor is excluded.', '',
              '## Separate GPU profiles', '', '| Renderer, 60 views | Profiles | Mean envelope ms | Active union ms/update | Vertex active ms/update | Fragment active ms/update |', '| --- | ---: | ---: | ---: | ---: | ---: |']
    for group in profiles:
        d = [group['gpu_envelope_ms'], group['gpu_active_union_ms'], group['stages']['Vertex'], group['stages']['Fragment']]
        lines.append('| ' + group['renderer'] + f' | {group["runs"]} | ' + ' | '.join(f'{v["mean"]:.3f} ± {v["sd"]:.3f}' if v['sd'] is not None else f'{v["mean"]:.3f} (single profile)' for v in d) + ' |')
    lines += ['', 'Five seconds of motion per profile, same all-process Metal System Trace mode, filtered to app depth-zero Active stages. Additional captures repeatedly failed export due to system-daemon timeline errors; failed captures are excluded. Single-profile KH trace repeat variation is unknown. Three independent unprofiled KH GPU-diagnostic trials are available above. Stage activity can overlap. All observed buffers have complete Vertex/Fragment pairs, one buffer/update and zero idle-before buffers. Profiling CPU/cadence are excluded from primary trials; GPU frequency and capture effects can vary. Trace envelopes and command-buffer diagnostic envelopes have different boundaries and are presented separately. Raw traces/XML remain in ignored DerivedData.', '']
    (ROOT / 'results.md').write_text('\n'.join(lines))
    selected = [next(g for g in summaries if g['count'] == 60 and g['stage'] == stage and g['renderer'] == renderer)
                for stage, renderer in [('Before', 'kh'), ('Adaptive', 'kh'), ('Adaptive', 'swiftui')]]
    fig, axes = plt.subplots(1, 3, figsize=(12, 4.2), layout='constrained')
    labels = ['KH before', 'KH adaptive', 'SwiftUI']
    for ax, key, title, unit in zip(axes, metrics[:3], ['Whole-app CPU', 'Extra app footprint', 'Update cadence'], ['ms/update', 'MiB', 'updates/s']):
        ax.bar(labels, [g['metrics'][key]['mean'] for g in selected], yerr=[g['metrics'][key]['sd'] for g in selected],
               color=['#aebdcc', '#438ec8', '#41a787'], capsize=4)
        ax.set_title(title); ax.set_ylabel(unit); ax.grid(axis='y', alpha=.2); ax.set_axisbelow(True)
    fig.suptitle('60 distinct gradients · M1 iPad · 3 Release trials per renderer')
    fig.savefig(ROOT / 'performance-comparison.png', dpi=150)
    plt.close(fig)
    print('\n'.join(lines))


if __name__ == '__main__':
    main()
