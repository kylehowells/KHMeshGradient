#!/usr/bin/env python3
"""Extract app command-buffer GPU intervals from xctrace XML exports.

Export time-info and metal-gpu-intervals tables separately. Only complete,
depth-zero Active vertex+fragment command buffers within the benchmark's active
phase are counted. Raw traces contain device/process data: publish aggregates,
not the trace or XML. These intervals exclude the display compositor.
"""
import argparse
import collections
import json
import statistics
import xml.etree.ElementTree as ET
from pathlib import Path


def document(path):
    root = ET.parse(path).getroot()
    ids = {e.attrib['id']: e for e in root.iter() if 'id' in e.attrib}
    def resolve(element):
        return ids[element.attrib['ref']] if 'ref' in element.attrib else element
    return root, resolve


def extract(time_path, gpu_path, run_path):
    run = json.loads(run_path.read_text())
    active = next(p for p in run['phases'] if p['name'] == 'active')
    time_root, resolve = document(time_path)
    fields = [resolve(e) for e in time_root.find('.//row')]
    epoch = int(fields[1].text)
    numerator, denominator = (int(resolve(e).text) for e in fields[3])
    origin = epoch * numerator / denominator / 1e9
    lo, hi = active['start']['wallTime'] - origin, active['end']['wallTime'] - origin
    idle = next(p for p in run['phases'] if p['name'] == 'idle-before')
    idle_lo, idle_hi = idle['start']['wallTime'] - origin, idle['end']['wallTime'] - origin
    idle_buffers = set()
    root, resolve = document(gpu_path)
    buffers = collections.defaultdict(list)
    active_intervals = []
    channel_intervals = collections.defaultdict(list)
    for row in root.findall('.//row'):
        fields = [resolve(e) for e in row]
        if not fields[10].attrib.get('fmt', '').startswith('KHMeshGradientExample '):
            continue
        if fields[5].text != '0' or fields[7].text != 'Active':
            continue
        start, duration = int(fields[0].text) / 1e9, int(fields[1].text) / 1e9
        if start >= idle_lo and start + duration <= idle_hi:
            idle_buffers.add(fields[15].text)
        if start < lo or start + duration > hi:
            continue
        active_intervals.append((start, start + duration))
        channel_intervals[fields[2].text].append((start, start + duration))
        buffers[fields[15].text].append((fields[2].text, start, start + duration))
    complete = [rows for rows in buffers.values() if {'Vertex', 'Fragment'}.issubset({r[0] for r in rows})]
    durations = sorted((max(r[2] for r in rows) - min(r[1] for r in rows)) * 1000 for rows in complete)
    if not durations:
        raise ValueError('No complete app command buffers inside the active phase')
    union_seconds, previous_end = 0, -1
    for start, end in sorted(active_intervals):
        union_seconds += max(0, end - max(start, previous_end))
        previous_end = max(previous_end, end)
    channel_unions = {}
    for channel, intervals in channel_intervals.items():
        total, previous_end = 0, -1
        for start, end in sorted(intervals):
            total += max(0, end - max(start, previous_end))
            previous_end = max(previous_end, end)
        channel_unions[channel] = total * 1000 / active['updateCount']
    return {
        'runID': run['runID'], 'renderer': run['renderer'], 'count': run['count'], 'mesh': run['mesh'],
        'width': run['viewWidthPoints'], 'height': run['viewHeightPoints'], 'requestedFPS': run['requestedFPS'],
        'scope': 'App command-buffer vertex/fragment GPU envelope, excluding compositor',
        'activeSeconds': hi - lo, 'activeUpdates': active['updateCount'],
        'observedCommandBuffers': len(buffers), 'completeCommandBuffers': len(complete),
        'incompleteCommandBuffersExcluded': len(buffers) - len(complete),
        'completeFractionOfObserved': len(complete) / len(buffers),
        'observedCommandBuffersPerUpdate': len(buffers) / active['updateCount'],
        'idleBeforeObservedAppCommandBuffers': len(idle_buffers),
        'observedGPUActiveUnionMSPerUpdate': union_seconds * 1000 / active['updateCount'],
        'observedGPUStageActiveUnionMSPerUpdate': channel_unions,
        'observedGPUActiveFraction': union_seconds / (hi - lo),
        'observedGPUChannels': sorted({r[0] for rows in buffers.values() for r in rows}),
        'gpuEnvelopeMeanMS': statistics.mean(durations), 'gpuEnvelopeMedianMS': statistics.median(durations),
        'gpuEnvelopeP95MS': durations[int((len(durations) - 1) * .95)],
        'gpuEnvelopeMaxMS': max(durations),
        'model': run['model'], 'os': run['os'], 'isSimulator': run['isSimulator'], 'build': run['build'],
        'subdivisions': run['subdivisions'],
        'geometryResolutionScope': run.get('geometryResolutionScope', 'KH-setting-only; SwiftUI-managed'),
        'measuredExecutableSHA256': run.get('measuredExecutableSHA256'),
        'thermalMax': max(s['thermalState'] for p in run['phases'] for s in p['memorySamples']),
        'lowPowerMode': any(s['lowPowerMode'] for p in run['phases'] for s in p['memorySamples']),
        'interruptions': run['interruptions'], 'allMeshesVisible': run['allMeshesVisible'],
        'gradientVariant': run.get('gradientVariant', 'shared-fixture'),
        'randomSeed': run.get('randomSeed', 'none'), 'uniqueFixtureCount': run.get('uniqueFixtureCount'),
        'fixtureSHA256': run.get('fixtureSHA256'),
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--time', type=Path, required=True)
    parser.add_argument('--gpu', type=Path, required=True)
    parser.add_argument('--run', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    result = extract(args.time, args.gpu, args.run)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
