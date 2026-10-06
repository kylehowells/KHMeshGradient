# Comparison capture

The checked-in contact sheet contains nine pairs of actual renders, not mockups.
The left column is KHMeshGradientView's Metal output and the right column is
SwiftUI MeshGradient. Captured on an iPad Simulator running iOS 26.5, using
Xcode 26.6. Each render is 360 × 240 pixels, with scale 1 and light appearance.

![Side-by-side comparisons](contact-sheet.png)

Inputs are defined in `Example/Sources/MeshSamples.swift`. Colors use fixed
sRGB values rather than dynamic system colors, ensuring that both views receive
the same values. Background fill, interpolation mode, and color space are shared.
The transparent fixture is composited over white on both sides of the sheet.

`raw/` contains the unmodified PNG captures and their manifest.
`comparison-metrics.json` records RGB differences after compositing over white.
The contact sheet script adds labels and layout, without correcting colors,
resizing, or replacing either renderer's output.

| Fixture | Mean absolute RGB difference, 0–255 | 95th percentile |
| --- | ---: | ---: |
| Four corners | 0.750 | 2 |
| Regular 3 × 3 rainbow | 0.727 | 2 |
| Moved center | 3.693 | 14 |
| Irregular 4 × 4 | 2.182 | 8 |
| Explicit Bézier handles | 0.765 | 2 |
| Unsmoothed colors | 0.347 | 1 |
| Inset mesh with background | 2.533 | 10 |
| Transparency | 0.552 | 2 |
| Perceptual colors | 0.869 | 2 |

These are observational measurements, not a compatibility guarantee or pass/fail
threshold. The largest differences come from automatic geometry inference in
irregular grids. Two additional `*-explicit-swiftui.png` captures supply our
generated handles explicitly to SwiftUI, isolating automatic inference from
patch rendering. Their mean differences from the corresponding Metal render are
about 1.087 for the moved-center fixture and 0.838 for the 4 × 4 fixture.

SwiftUI's undocumented internal interpolation and rasterization can also change
between OS releases. Perceptual interpolation uses Oklab here; this is an
independent implementation rather than a dependency on Apple's private color math.

![Metal mesh and Bézier debug overlays](debug-sheet.png)

To regenerate, build the example into `DerivedData` and run
`Scripts/export_comparisons.sh SIMULATOR_UDID` on an already booted iOS 18+
Simulator. Install Python dependencies from `Scripts/requirements.txt`.
