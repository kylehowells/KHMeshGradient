# Repeated geometry-resolution measurements

Physical M1 iPad, iPadOS 18.6, Release; 60 distinct seed-42 organic gradients, 152×88 pt each, scale 2, requested 120 Hz. Three fresh processes per row. All runs retained; nominal thermal state, Low Power Mode off, no interruptions, all views visible, no GPU errors. KH idle-after submits zero frames.

| Renderer / subdivisions | CPU ms/update | Extra MiB | Updates/s | KH presentation/s | KH GPU batch envelope ms |
| --- | ---: | ---: | ---: | ---: | ---: |
| KH / 4 | 4.82 ± 0.05 | 48.51 ± 0.04 | 119.81 ± 0.00 | 119.93 ± 0.00 | 1.22 ± 0.01 |
| KH / 8 | 4.78 ± 0.01 | 48.94 ± 0.08 | 119.81 ± 0.00 | 119.93 ± 0.00 | 1.28 ± 0.00 |
| KH / 12 | 4.78 ± 0.02 | 50.22 ± 0.05 | 119.81 ± 0.00 | 119.93 ± 0.00 | 1.40 ± 0.01 |
| KH / 16 | 4.78 ± 0.02 | 51.87 ± 0.05 | 119.81 ± 0.00 | 119.93 ± 0.00 | 1.66 ± 0.00 |
| KH / 24 | 4.79 ± 0.02 | 55.31 ± 0.09 | 119.81 ± 0.00 | 119.93 ± 0.00 | 2.52 ± 0.00 |
| KH / 32 | 4.72 ± 0.04 | 56.66 ± 0.04 | 119.81 ± 0.00 | 119.93 ± 0.00 | 4.39 ± 0.00 |
| KH / 48 | 4.48 ± 0.09 | 68.42 ± 0.22 | 119.81 ± 0.00 | 119.93 ± 0.00 | 6.42 ± 0.06 |
| KH / 96 | 4.35 ± 0.04 | 104.69 ± 0.72 | 99.71 ± 0.11 | 49.91 ± 0.04 | 10.45 ± 0.01 |
| SwiftUI / managed | 3.39 ± 0.02 | 72.78 ± 2.70 | 118.10 ± 0.90 | — | — |

CPU is consumed whole-process time, not setter latency. GPU diagnostics sum equal shares of a completed shared command buffer; these are grid envelopes, not isolated per-view costs. Callback rate does not establish SwiftUI presentation cadence. The 96-subdivision setting falls below 120 Hz, so its CPU/update value describes a different throughput.

## Separate GPU profiles

CPU/cadence under profiling are excluded above. Both renderers use the same all-process Metal System Trace mode, filtered to app depth-zero Active stages. Stages overlap; their times cannot be added.

| Renderer | Mean command envelope ms | Active union ms/update | Vertex active ms/update | Fragment active ms/update |
| --- | ---: | ---: | ---: | ---: |
| kh / 16 | 1.437 ± 0.067 | 1.132 ± 0.006 | 0.425 ± 0.002 | 1.005 ± 0.008 |
| swiftui | 1.811 ± 0.037 | 1.709 ± 0.007 | 0.266 ± 0.003 | 1.446 ± 0.007 |

Each profile covers five seconds of motion. Frequency and capture overhead can affect GPU intervals; this is one device/workload, not universal parity. Raw traces/XML remain in ignored DerivedData. Every successful profile has complete Vertex/Fragment pairs, one observed app command buffer per update, zero idle-before buffers, and the matching input hash.
