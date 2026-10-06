#!/usr/bin/env python3
"""Compose real Simulator exports, preserving every sample, and measure differences.

Usage: python3 Scripts/make_contact_sheet.py Documentation/Comparisons/raw
Requires Pillow and NumPy. This does not synthesize or modify the gradient renders.
"""
import argparse
import json
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont


def font(size, bold=False):
    paths = [
        Path('/System/Library/Fonts/Supplemental/Arial Bold.ttf' if bold else '/System/Library/Fonts/Supplemental/Arial.ttf'),
        Path('/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf' if bold else '/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf'),
    ]
    for path in paths:
        if path.exists():
            return ImageFont.truetype(str(path), size)
    return ImageFont.load_default()


def over_white(image):
    image = image.convert('RGBA')
    white = Image.new('RGBA', image.size, 'white')
    return Image.alpha_composite(white, image).convert('RGB')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('raw', type=Path)
    parser.add_argument('--output', type=Path, default=Path('Documentation/Comparisons'))
    args = parser.parse_args()
    manifest = json.loads((args.raw / 'manifest.json').read_text())
    samples = manifest['samples']
    image_width, image_height = manifest['width'], manifest['height']
    margin, gap, row_height = 28, 20, image_height + 70
    width = margin * 2 + image_width * 2 + gap
    height = 120 + row_height * len(samples) + 32
    sheet = Image.new('RGB', (width, height), '#f2f3f7')
    draw = ImageDraw.Draw(sheet)
    draw.text((margin, 18), 'Mesh gradient comparison', font=font(26, True), fill='#152035')
    draw.text((margin, 53), f"Actual Metal / SwiftUI renders · iOS {manifest['os']} · {image_width} × {image_height}px", font=font(14), fill='#536078')
    draw.text((margin, 86), 'KHMeshGradientView · Metal', font=font(16, True), fill='#152035')
    draw.text((margin + image_width + gap, 86), 'SwiftUI · MeshGradient', font=font(16, True), fill='#152035')
    metrics = []
    for index, sample in enumerate(samples):
        top = 120 + index * row_height
        draw.text((margin, top), sample['title'], font=font(17, True), fill='#152035')
        draw.text((margin, top + 25), sample['detail'], font=font(13), fill='#536078')
        ours_raw = Image.open(args.raw / f"{sample['id']}-kh.png")
        swiftui_raw = Image.open(args.raw / f"{sample['id']}-swiftui.png")
        ours, swiftui = over_white(ours_raw), over_white(swiftui_raw)
        assert ours.size == swiftui.size == (image_width, image_height)
        sheet.paste(ours, (margin, top + 48))
        sheet.paste(swiftui, (margin + image_width + gap, top + 48))
        delta = np.abs(np.asarray(ours, dtype=np.float32) - np.asarray(swiftui, dtype=np.float32))
        metrics.append({
            'id': sample['id'], 'mean_absolute_rgb_8bit': round(float(delta.mean()), 3),
            'p95_absolute_rgb_8bit': round(float(np.percentile(delta, 95)), 3),
            'max_absolute_rgb_8bit': int(delta.max()),
        })
    args.output.mkdir(parents=True, exist_ok=True)
    sheet.save(args.output / 'contact-sheet.png')
    report = {'capture': manifest, 'measurement': 'Absolute encoded-sRGB differences after compositing both images over white. These are observational metrics, not a pixel-parity promise.', 'metrics': metrics}
    (args.output / 'comparison-metrics.json').write_text(json.dumps(report, indent=2) + '\n')
    # Dedicated debug sheet, again using actual exported GPU images.
    debug_samples = [sample for sample in samples if sample['id'] in ('rainbow', 'organic', 'bezier')]
    debug = Image.new('RGB', (width, 90 + (image_height + 52) * len(debug_samples)), '#f2f3f7')
    dd = ImageDraw.Draw(debug)
    dd.text((margin, 18), 'Mesh and Bézier handle debugging', font=font(26, True), fill='#152035')
    dd.text((margin, 56), 'Gradient', font=font(16), fill='#536078')
    dd.text((margin + image_width + gap, 56), 'Control-point overlay', font=font(16), fill='#536078')
    for index, sample in enumerate(debug_samples):
        top = 90 + index * (image_height + 52)
        dd.text((margin, top), sample['title'], font=font(17, True), fill='#152035')
        debug.paste(over_white(Image.open(args.raw / f"{sample['id']}-kh.png")), (margin, top + 30))
        debug.paste(over_white(Image.open(args.raw / f"{sample['id']}-debug.png")), (margin + image_width + gap, top + 30))
    debug.save(args.output / 'debug-sheet.png')
    print(json.dumps(metrics, indent=2))


if __name__ == '__main__':
    main()
