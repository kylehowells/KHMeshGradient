# Optimization results

Physical M1 iPad Pro, iPadOS 18.6, Release. Three fresh-process trials per row; 60 unique 4×4 gradients, seed 42, 152×88 pt each, scale 2, requested 120 Hz. Identical palettes, geometry, trajectories, viewport, and 48 subdivisions. Mean ± sample standard deviation.

| Version | Renderer | CPU ms/update | Extra app MiB | Updates/s | Presented/s per view | Command buffers/update | Render passes/update |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Original | kh | 20.58 ± 0.36 | 116.05 ± 3.04 | 53.2 ± 1.1 | 53.3 ± 1.1 | 60.00 ± 0.00 | 60.00 ± 0.00 |
| Original | swiftui | 3.38 ± 0.01 | 75.87 ± 6.13 | 118.8 ± 1.0 | — | — | — |
| Command batching | kh | 5.45 ± 0.03 | 62.52 ± 0.39 | 119.8 ± 0.0 | 119.9 ± 0.0 | 1.00 ± 0.00 | 60.00 ± 0.00 |
| Command batching | swiftui | 3.37 ± 0.03 | 69.72 ± 3.00 | 118.3 ± 0.3 | — | — | — |
| Command batching, diagnostics off | kh | 5.37 ± 0.03 | 62.53 ± 0.61 | 119.8 ± 0.0 | — | — | — |
| Optimized MRT | kh | 4.64 ± 0.05 | 68.47 ± 0.42 | 119.8 ± 0.0 | 119.9 ± 0.0 | 1.00 ± 0.00 | 8.00 ± 0.00 |
| Optimized MRT | swiftui | 3.38 ± 0.03 | 74.40 ± 4.64 | 118.1 ± 0.7 | — | — | — |
| Optimized MRT, diagnostics off | kh | 4.48 ± 0.04 | 68.51 ± 0.40 | 119.8 ± 0.0 | — | — | — |

CPU is whole-process consumed CPU time per update, not main-thread latency. Memory is app physical footprint above each fresh blank baseline. Update callbacks do not establish SwiftUI presentation cadence. KH presentation rates come from drawable timestamps. CPU/memory trials run without Instruments. GPU diagnostic times in the raw files allocate each completed command-buffer envelope equally among its participating views; they are not isolated per-mesh GPU timings. Original per-mesh command envelopes cannot be summed and treated as an overlap-free scene GPU measurement.

All published trials have nominal thermal state, Low Power Mode off, no active-app interruptions, no GPU errors, and all meshes visible. Every KH idle-after phase submits zero frames. Build and fixture hashes are preserved in summary.json and every raw trial.
