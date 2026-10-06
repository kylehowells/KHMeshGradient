#!/usr/bin/env python3
"""Write reviewable Markdown tables from benchmark summaries, without rounding raw data."""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent / 'Documentation/Benchmarks'


def number(group, name, digits=2, spread=True):
    value = group['metrics'][name]
    mean = f'{value["mean"]:.{digits}f}'
    return f'{mean} ± {value["sd"]:.{digits}f}' if spread else mean


def main():
    data = json.loads((ROOT / 'summary.json').read_text())
    lines = ['# Measured results', '',
             'Mean ± sample standard deviation across fresh process launches. CPU is whole-app CPU time per mesh update; memory is physical footprint in MiB. CADisplayLink cadence is measured separately from GPU time and physical presentation.', '',
             '| Surface / mesh | Views | Renderer | Runs | CPU ms/update | Extra footprint MiB | Total footprint MiB | Updates/s | p95 callback gap ms |',
             '| --- | ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: |']
    for g in data['groups']:
        lines.append(f'| {g["width"]}×{g["height"]} / {g["mesh"]} | {g["count"]} | {g["renderer"]} | {g["runs"]} | {number(g,"cpu_ms_per_update")} | {number(g,"incremental_footprint_mb")} | {number(g,"footprint_mb")} | {number(g,"callback_fps",1)} | {number(g,"callback_p95_ms")} |')
    lines += ['', '## KH direct rendering diagnostics', '',
              'CPU wall/draw excludes property setters and includes waits. GPU/draw is the completed command-buffer interval, excluding the compositor. Presented/s comes from drawable presentation timestamps. Summing GPU intervals across views would double count overlapping execution.', '',
              '| Surface / mesh | Views | CPU wall ms/draw | Snapshot ms | Encoding ms | Scheduling wait ms | GPU ms/draw | Presented/s/view | Idle-after submissions |',
              '| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |']
    for g in data['groups']:
        if g['renderer'] != 'kh': continue
        keys = ['kh_cpu_wall_ms_per_mesh_draw', 'kh_snapshot_ms_per_mesh_draw', 'kh_encoding_ms_per_mesh_draw', 'kh_scheduling_wait_ms_per_mesh_draw', 'kh_gpu_ms_per_mesh_draw']
        values = ' | '.join(number(g, k, 3) for k in keys)
        lines.append(f'| {g["width"]}×{g["height"]} / {g["mesh"]} | {g["count"]} | {values} | {number(g,"kh_presented_fps_per_view",1)} | {number(g,"idle_after_metal_submissions",0,False)} |')
    controls_path = ROOT / 'controls/summary.json'
    if controls_path.exists():
        controls = json.loads(controls_path.read_text())
        lines += ['', '## Diagnostics disabled', '',
                  'Same executable and whole-process monitor; Metal timing/presentation callbacks disabled. These are additional trials, not replacements hidden in the primary table.', '',
                  '| Surface / mesh | Views | Runs | CPU ms/update | Extra footprint MiB | Updates/s | Change in mean CPU vs diagnostics enabled |',
                  '| --- | ---: | ---: | ---: | ---: | ---: | ---: |']
        for g in controls['groups']:
            matching = next(p for p in data['groups'] if all(p[k] == g[k] for k in ('width','height','mesh','count','renderer','requestedFPS')))
            change = (g['metrics']['cpu_ms_per_update']['mean'] / matching['metrics']['cpu_ms_per_update']['mean'] - 1) * 100
            lines.append(f'| {g["width"]}×{g["height"]} / {g["mesh"]} | {g["count"]} | {g["runs"]} | {number(g,"cpu_ms_per_update")} | {number(g,"incremental_footprint_mb")} | {number(g,"callback_fps",1)} | {change:+.1f}% |')
    gpu = [json.loads(p.read_text()) for p in sorted((ROOT / 'gpu').glob('120hz-*.json'))]
    if gpu:
        lines += ['', '## Separate 120 Hz GPU profiles', '',
                  'One 12-second active capture per renderer/layout. Command intervals are GPU envelopes for complete Vertex + Fragment buffers, not physical frame latency. The Active union uses all captured app stages, counts overlaps once, and can underestimate activity when intervals are missing. It excludes the compositor.', '',
                  '| Surface | Views | Renderer | Observed buffers/update | Command mean ms | Median ms | p95 ms | Complete / observed buffers | Observed Active union ms/update |',
                  '| --- | ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: |']
        for g in gpu:
            lines.append(f'| {g["width"]}×{g["height"]} | {g["count"]} | {g["renderer"]} | {g["observedCommandBuffersPerUpdate"]:.2f} | {g["gpuEnvelopeMeanMS"]:.3f} | {g["gpuEnvelopeMedianMS"]:.3f} | {g["gpuEnvelopeP95MS"]:.3f} | {g["completeCommandBuffers"]} / {g["observedCommandBuffers"]} | {g.get("observedGPUActiveUnionMSPerUpdate",0):.3f} |')
        lines += ['', 'The 60-view SwiftUI trace has one complete GPU command buffer per update for the entire grid. A KH buffer renders one mesh. Their command-buffer means must not be compared as if they represented the same number of views.', '']
    lines += ['', '## Reproducibility', '',
              f'Primary runs: {len(data["runs"])}. All environments valid: {all(g["valid_environment"] for g in data["groups"])}.', '',
              'Executable SHA-256:', '']
    lines.extend(f'- `{value}`' for value in sorted({r['executable_sha256'] for r in data['runs']}))
    lines += ['', 'Source tree SHA-256 (Sources + Example Swift):', '']
    lines.extend(f'- `{value}`' for value in sorted({r['source_sha256'] for r in data['runs']}))
    (ROOT / 'results.md').write_text('\n'.join(lines) + '\n')


if __name__ == '__main__':
    main()
