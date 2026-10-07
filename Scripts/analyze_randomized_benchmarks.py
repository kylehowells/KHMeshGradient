#!/usr/bin/env python3
"""Compare shared-fixture and unique-per-view trials from the same executable."""
import collections
import csv
import json
import statistics
from pathlib import Path

import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt

from analyze_benchmarks import measure

ROOT = Path(__file__).resolve().parent.parent / 'Documentation/Benchmarks/Randomized'


def main():
    raw = [json.loads(p.read_text()) for p in sorted((ROOT / 'raw').glob('*.json'))]
    if not raw:
        raise SystemExit('No randomized experiment trials')
    rows, grouped, pairs = [], collections.defaultdict(list), collections.defaultdict(dict)
    for d in raw:
        r = measure(d)
        r.update({k: d[k] for k in ('gradientVariant','randomSeed','uniqueFixtureCount','fixtureSHA256')})
        assert r['all_visible'] and not r['interruptions'] and not r['low_power'] and r['thermal_max']==0
        assert r['build']=='Release' and not d['isSimulator'] and r['gpu_errors']==0
        expected = 60 if r['gradientVariant']=='randomized-per-view' else 1
        assert r['count']==60 and r['uniqueFixtureCount']==expected
        assert len(d['fixtureInputs'])==60
        rows.append(r)
        grouped[(r['gradientVariant'],r['renderer'])].append(r)
        repetition = r['runID'].split('-r')[1].split('-')[0]
        pairs[(r['gradientVariant'],r['randomSeed'],repetition)][r['renderer']] = d
    for pair in pairs.values():
        if set(pair)=={'kh','swiftui'}:
            assert pair['kh']['fixtureSHA256']==pair['swiftui']['fixtureSHA256']
            assert pair['kh']['fixtureInputs']==pair['swiftui']['fixtureInputs']
            assert pair['kh']['perViewFixtureSHA256']==pair['swiftui']['perViewFixtureSHA256']
    assert len({r['executable_sha256'] for r in rows})==1
    assert len({r['source_sha256'] for r in rows})==1
    metrics = ['cpu_ms_per_update','incremental_footprint_mb','footprint_mb','callback_fps','callback_p95_ms',
               'setter_mean_ms','kh_gpu_ms_per_mesh_draw','kh_presented_fps_per_view','idle_after_metal_submissions']
    groups = []
    for (variant,renderer), values in sorted(grouped.items()):
        g = {'variant':variant,'renderer':renderer,'runs':len(values),'metrics':{}}
        for k in metrics:
            samples = [r[k] for r in values if r[k] is not None]
            if samples:
                mean = statistics.mean(samples); sd = statistics.stdev(samples) if len(samples)>1 else 0
                g['metrics'][k] = {'mean':mean,'sd':sd,'minimum':min(samples),'maximum':max(samples),
                                   'cv_percent':sd/abs(mean)*100 if mean else 0}
        groups.append(g)
    (ROOT / 'summary.json').write_text(json.dumps({'runs':rows,'groups':groups,'validatedPairs':len(pairs)},indent=2)+'\n')
    with (ROOT / 'runs.csv').open('w',newline='') as output:
        writer = csv.DictWriter(output,fieldnames=list(rows[0]),lineterminator='\n')
        writer.writeheader(); writer.writerows(rows)
    labels = ['Original fixture\n(distinct motion phases)','Random palette + geometry\nfor every view']
    fig, axes = plt.subplots(1,3,figsize=(13,4.5))
    for renderer, offset, color, label in [('kh',-.18,'#7260d3','KHMeshGradientView'),('swiftui',.18,'#008d91','SwiftUI MeshGradient')]:
        for col, metric, ylabel in [(0,'cpu_ms_per_update','Whole-app CPU / update (ms)'),
                                    (1,'incremental_footprint_mb','Extra app physical footprint (MiB)'),
                                    (2,'callback_fps','Mesh update callbacks / second')]:
            values = [next((g for g in groups if g['variant']==v and g['renderer']==renderer),None) for v in ('shared-fixture','randomized-per-view')]
            valid = [(i,g) for i,g in enumerate(values) if g]
            axes[col].bar([i+offset for i,g in valid],[g['metrics'][metric]['mean'] for i,g in valid],width=.36,
                          yerr=[g['metrics'][metric]['sd'] for i,g in valid],capsize=4,color=color,label=label)
            axes[col].set_ylabel(ylabel); axes[col].set_xticks([0,1],labels); axes[col].grid(axis='y',alpha=.2)
    axes[2].axhline(120,color='#777',ls='--',lw=1); axes[2].set_ylim(0,130)
    for ax in axes: ax.legend(fontsize=8)
    fig.suptitle('60 visible 4×4 meshes · 152×88 pt · requested 120 Hz\nPhysical M1 iPad Pro / iPadOS 18.6 · same Release executable · mean ± sample SD')
    fig.tight_layout(rect=(0,0,1,.91)); fig.savefig(ROOT/'randomized-comparison.png',dpi=180); plt.close(fig)
    lines = ['# Randomized stress-test results','',
             'Three fresh trials per renderer/variant. Random trials use seeds 42, 2026, and 8675309; palettes and initial interior geometry differ for all 60 views. Each seed is paired exactly between renderers. Variation includes input variation across seeds. All metrics below come from unprofiled runs.','',
             '| Inputs | Renderer | Trials | CPU ms/update | Extra app MiB | Total app MiB | Updates/s | p95 callback gap ms |',
             '| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |']
    def fmt(g,k,digits=2):
        m=g['metrics'][k]; return f'{m["mean"]:.{digits}f} ± {m["sd"]:.{digits}f}'
    for g in groups:
        lines.append(f'| {g["variant"]} | {g["renderer"]} | {g["runs"]} | {fmt(g,"cpu_ms_per_update")} | {fmt(g,"incremental_footprint_mb")} | {fmt(g,"footprint_mb")} | {fmt(g,"callback_fps",1)} | {fmt(g,"callback_p95_ms")} |')
    gpu = [json.loads(p.read_text()) for p in sorted((ROOT/'gpu').glob('*.json'))]
    if gpu:
        matched = [d for d in raw if d['randomSeed']=='42']
        for g in gpu:
            assert g['uniqueFixtureCount']==60 and g['randomSeed']=='42'
            assert g['thermalMax']==0 and not g['lowPowerMode'] and not g['interruptions'] and g['allMeshesVisible']
            assert all(d['fixtureSHA256']==g['fixtureSHA256'] for d in matched)
        lines += ['', '## Separate randomized GPU profiles','',
                  'Seed 42, one 12-second active profile per renderer. GPU command envelopes exclude the compositor. A command buffer can render many meshes; command means have different scopes. The union counts overlapping captured app Active stages once and can underestimate missing intervals. Profiled CPU and cadence do not replace the unprofiled values above.','',
                  '| Renderer | Unique inputs | Buffers/update | Command mean ms | Median ms | p95 ms | Complete / observed buffers | Observed Active union ms/update | Idle-before buffers |',
                  '| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |']
        for g in gpu:
            lines.append(f'| {g["renderer"]} | {g["uniqueFixtureCount"]} | {g["observedCommandBuffersPerUpdate"]:.2f} | {g["gpuEnvelopeMeanMS"]:.3f} | {g["gpuEnvelopeMedianMS"]:.3f} | {g["gpuEnvelopeP95MS"]:.3f} | {g["completeCommandBuffers"]} / {g["observedCommandBuffers"]} | {g["observedGPUActiveUnionMSPerUpdate"]:.3f} | {g["idleBeforeObservedAppCommandBuffers"]} |')
    lines += ['',f'Validated renderer pairs: {len(pairs)}. Executable SHA-256: `{rows[0]["executable_sha256"]}`.',
              '',f'Source tree SHA-256: `{rows[0]["source_sha256"]}`.', '']
    (ROOT/'results.md').write_text('\n'.join(lines))
    print('\n'.join(lines[:12]))


if __name__=='__main__': main()
