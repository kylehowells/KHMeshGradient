#!/usr/bin/env python3
"""Measure actual KH/SwiftUI exports at several subdivision and image sizes.

Both renderers receive identical raw inputs. KH n=128 is a convergence
reference, not ground truth. SwiftUI ImageRenderer results are not GPU timings.
"""
import argparse
import hashlib
import json
from pathlib import Path

import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import numpy as np
from PIL import Image, ImageDraw

from make_contact_sheet import font, over_white


def image(path, expected_size):
    result = np.asarray(Image.open(path).convert('RGBA'), dtype=np.float32)
    assert result.shape[:2] == (expected_size[1], expected_size[0]), path
    return result


def composite(rgba, background):
    alpha = rgba[:, :, 3:4] / 255
    return rgba[:, :, :3] * alpha + background * (1 - alpha)


def metrics(a, b):
    delta = np.abs(a - b)
    return {'mae': round(float(delta.mean()), 6),
            'p95_channel_error': round(float(np.percentile(delta, 95)), 6),
            'max_channel_error': round(float(delta.max()), 6),
            'fraction_pixels_over_2': round(float((delta.max(axis=2) > 2).mean()), 6)}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('raw', type=Path)
    parser.add_argument('--output', type=Path, default=Path('Documentation/Benchmarks/Geometry/images'))
    args = parser.parse_args()
    manifest = json.loads((args.raw / 'manifest.json').read_text())
    levels = manifest['subdivisions']
    assert levels[-1] == 128
    rows = []
    hashes = {}
    for capture in manifest['captures']:
        stem = capture['stem']
        size = (capture['width'], capture['height'])
        paths = [args.raw / f'{stem}-swiftui.png'] + [args.raw / f'{stem}-n{n}.png' for n in levels]
        for path in paths:
            hashes[path.name] = hashlib.sha256(path.read_bytes()).hexdigest()
        reference = image(paths[0], size)
        fine = image(paths[-1], size)
        for n in levels:
            ours = image(args.raw / f'{stem}-n{n}.png', size)
            rows.append({'id': capture['id'], 'width': size[0], 'height': size[1], 'subdivisions': n,
                         'vs_swiftui_white': metrics(composite(ours, 255), composite(reference, 255)),
                         'vs_swiftui_black': metrics(composite(ours, 0), composite(reference, 0)),
                         'vs_kh128_white': metrics(composite(ours, 255), composite(fine, 255)),
                         'vs_kh128_black': metrics(composite(ours, 0), composite(fine, 0)),
                         'alpha_mae_vs_swiftui': round(float(np.abs(ours[:, :, 3] - reference[:, :, 3]).mean()), 6),
                         'alpha_mae_vs_kh128': round(float(np.abs(ours[:, :, 3] - fine[:, :, 3]).mean()), 6)})
    args.output.mkdir(parents=True, exist_ok=True)
    report = {'capture': manifest, 'units': 'Encoded-sRGB 8-bit channel values; over white/black plus separate alpha.',
              'reference_caveat': 'KH128 estimates convergence; these observations do not establish SwiftUI pixel parity.',
              'metrics': rows, 'imageSHA256': hashes}
    (args.output / 'metrics.json').write_text(json.dumps(report, indent=2) + '\n')
    fig, axes = plt.subplots(1, 2, figsize=(12, 4.6), layout='constrained')
    widths = sorted({r['width'] for r in rows})
    for ax, key, title in zip(axes, ['vs_kh128_white', 'vs_swiftui_white'],
                               ['Tessellation error versus KH128', 'Difference versus SwiftUI']):
        for width in widths:
            values = [np.mean([r[key]['mae'] for r in rows if r['width'] == width and r['subdivisions'] == n]) for n in levels]
            ax.plot(levels, values, marker='o', label=f'{width}px wide · mean of 15 fixtures')
        ax.set_xscale('log', base=2)
        ax.set_xticks(levels, labels=[str(n) for n in levels])
        ax.set_xlabel('Subdivisions per patch axis')
        ax.set_ylabel('Mean absolute RGB error (8-bit)')
        ax.set_title(title)
        ax.grid(alpha=.2)
        ax.legend(fontsize=8)
    fig.suptitle(f'Actual physical iPad exports · iPadOS {manifest["os"]} · identical inputs')
    fig.savefig(args.output / 'error-by-resolution.png', dpi=150)
    plt.close(fig)
    selected = ['corners', 'organic', 'organic-explicit', 'strong-handles', 'random-17', 'perceptual']
    columns = [('SwiftUI', 'swiftui'), ('KH · 4', 'n4'), ('KH · 8', 'n8'), ('KH · 16', 'n16'), ('KH · 48', 'n48'), ('KH · 128', 'n128')]
    margin, gap, cell_width, cell_height = 24, 12, 304, 176
    sheet = Image.new('RGB', (margin * 2 + len(columns) * (cell_width + gap) - gap,
                              105 + len(selected) * (cell_height + 52) + margin), '#f2f3f7')
    draw = ImageDraw.Draw(sheet)
    draw.text((margin, 15), 'Subdivision sweep · actual GPU / SwiftUI image exports', font=font(25, True), fill='#152035')
    draw.text((margin, 50), f'iPadOS {manifest["os"]} · 304 × 176px · all inputs preserved · no resampling of gradients', font=font(15), fill='#536078')
    for column, (label, _) in enumerate(columns):
        draw.text((margin + column * (cell_width + gap), 80), label, font=font(18, True), fill='#152035')
    for row, id in enumerate(selected):
        capture = next(c for c in manifest['captures'] if c['id'] == id and c['width'] == 304)
        top = 105 + row * (cell_height + 52)
        draw.text((margin, top), capture['title'], font=font(18, True), fill='#152035')
        for column, (_, suffix) in enumerate(columns):
            rendered = over_white(Image.open(args.raw / f'{capture["stem"]}-{suffix}.png'))
            sheet.paste(rendered, (margin + column * (cell_width + gap), top + 32))
    sheet.save(args.output / 'contact-sheet.png')
    summary = []
    for width in widths:
        for n in levels:
            group = [r for r in rows if r['width'] == width and r['subdivisions'] == n]
            summary.append({'width': width, 'subdivisions': n,
                            'mean_mae_vs_kh128': float(np.mean([r['vs_kh128_white']['mae'] for r in group])),
                            'mean_mae_vs_swiftui': float(np.mean([r['vs_swiftui_white']['mae'] for r in group])),
                            'worst_fixture_mae_vs_kh128': max(r['vs_kh128_white']['mae'] for r in group)})
    (args.output / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(json.dumps(summary, indent=2))


if __name__ == '__main__':
    main()
