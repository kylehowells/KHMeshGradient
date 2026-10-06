# Measured results

Mean ± sample standard deviation across fresh process launches. CPU is whole-app CPU time per mesh update; memory is physical footprint in MiB. CADisplayLink cadence is measured separately from GPU time and physical presentation.

| Surface / mesh | Views | Renderer | Runs | CPU ms/update | Extra footprint MiB | Total footprint MiB | Updates/s | p95 callback gap ms |
| --- | ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 152×88 / organic | 15 | kh | 3 | 6.56 ± 0.03 | 45.69 ± 0.06 | 52.24 ± 0.05 | 119.8 ± 0.0 | 8.40 ± 0.00 |
| 152×88 / organic | 15 | swiftui | 3 | 2.95 ± 0.02 | 38.44 ± 0.16 | 45.04 ± 0.22 | 119.8 ± 0.0 | 8.42 ± 0.00 |
| 152×88 / organic | 30 | kh | 3 | 12.16 ± 0.04 | 77.24 ± 1.75 | 83.87 ± 1.67 | 89.6 ± 0.3 | 11.51 ± 0.05 |
| 152×88 / organic | 30 | swiftui | 5 | 2.26 ± 0.26 | 40.02 ± 4.84 | 46.60 ± 4.78 | 119.8 ± 0.0 | 8.57 ± 0.09 |
| 152×88 / organic | 60 | kh | 3 | 24.12 ± 0.07 | 122.84 ± 1.82 | 129.40 ± 1.83 | 44.8 ± 0.1 | 23.57 ± 0.24 |
| 152×88 / organic | 60 | swiftui | 3 | 3.36 ± 0.02 | 70.82 ± 3.23 | 77.40 ± 3.27 | 118.1 ± 0.6 | 8.42 ± 0.00 |
| 320×200 / organic | 5 | kh | 3 | 3.67 ± 0.04 | 34.95 ± 0.03 | 41.52 ± 0.01 | 119.8 ± 0.0 | 8.43 ± 0.00 |
| 320×200 / organic | 5 | swiftui | 3 | 2.66 ± 0.10 | 32.32 ± 0.27 | 38.90 ± 0.28 | 119.8 ± 0.0 | 8.43 ± 0.00 |
| 320×200 / organic | 15 | kh | 3 | 6.56 ± 0.01 | 81.91 ± 0.15 | 88.56 ± 0.15 | 119.8 ± 0.0 | 8.41 ± 0.00 |
| 320×200 / organic | 15 | swiftui | 3 | 3.85 ± 0.01 | 91.27 ± 0.12 | 97.85 ± 0.06 | 119.8 ± 0.0 | 8.47 ± 0.00 |
| 320×200 / rainbow | 5 | kh | 3 | 3.53 ± 0.01 | 31.75 ± 0.03 | 38.34 ± 0.05 | 119.8 ± 0.0 | 8.41 ± 0.00 |
| 320×200 / rainbow | 5 | swiftui | 3 | 2.73 ± 0.01 | 31.33 ± 0.21 | 37.95 ± 0.28 | 119.8 ± 0.0 | 8.43 ± 0.01 |
| 320×200 / rainbow | 15 | kh | 3 | 4.97 ± 0.06 | 71.57 ± 0.08 | 78.14 ± 0.07 | 119.8 ± 0.0 | 8.41 ± 0.00 |
| 320×200 / rainbow | 15 | swiftui | 3 | 3.90 ± 0.00 | 91.12 ± 0.21 | 97.70 ± 0.27 | 119.8 ± 0.0 | 8.46 ± 0.01 |

## KH direct rendering diagnostics

CPU wall/draw excludes property setters and includes waits. GPU/draw is the completed command-buffer interval, excluding the compositor. Presented/s comes from drawable presentation timestamps. Summing GPU intervals across views would double count overlapping execution.

| Surface / mesh | Views | CPU wall ms/draw | Snapshot ms | Encoding ms | Scheduling wait ms | GPU ms/draw | Presented/s/view | Idle-after submissions |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 152×88 / organic | 15 | 0.140 ± 0.001 | 0.076 ± 0.000 | 0.029 ± 0.000 | 0.031 ± 0.000 | 0.546 ± 0.000 | 119.9 ± 0.0 | 0 |
| 152×88 / organic | 30 | 0.140 ± 0.001 | 0.076 ± 0.000 | 0.029 ± 0.000 | 0.031 ± 0.000 | 0.337 ± 0.001 | 89.6 ± 0.3 | 0 |
| 152×88 / organic | 60 | 0.140 ± 0.001 | 0.078 ± 0.001 | 0.030 ± 0.000 | 0.027 ± 0.000 | 0.278 ± 0.001 | 44.9 ± 0.1 | 0 |
| 320×200 / organic | 5 | 0.213 ± 0.002 | 0.112 ± 0.001 | 0.044 ± 0.001 | 0.049 ± 0.001 | 0.602 ± 0.000 | 119.9 ± 0.0 | 0 |
| 320×200 / organic | 15 | 0.139 ± 0.001 | 0.076 ± 0.000 | 0.028 ± 0.000 | 0.031 ± 0.000 | 0.541 ± 0.000 | 119.9 ± 0.0 | 0 |
| 320×200 / rainbow | 5 | 0.271 ± 0.002 | 0.116 ± 0.000 | 0.067 ± 0.001 | 0.075 ± 0.000 | 0.320 ± 0.000 | 119.9 ± 0.0 | 0 |
| 320×200 / rainbow | 15 | 0.137 ± 0.001 | 0.062 ± 0.001 | 0.027 ± 0.000 | 0.042 ± 0.001 | 0.325 ± 0.000 | 119.9 ± 0.0 | 0 |

## Diagnostics disabled

Same executable and whole-process monitor; Metal timing/presentation callbacks disabled. These are additional trials, not replacements hidden in the primary table.

| Surface / mesh | Views | Runs | CPU ms/update | Extra footprint MiB | Updates/s | Change in mean CPU vs diagnostics enabled |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 152×88 / organic | 15 | 3 | 6.56 ± 0.02 | 45.68 ± 0.02 | 119.8 ± 0.0 | -0.1% |
| 152×88 / organic | 30 | 3 | 12.13 ± 0.05 | 78.57 ± 0.67 | 89.1 ± 0.6 | -0.2% |
| 152×88 / organic | 60 | 3 | 24.13 ± 0.08 | 123.88 ± 1.64 | 44.8 ± 0.1 | +0.0% |
| 320×200 / organic | 15 | 3 | 6.54 ± 0.01 | 81.87 ± 0.09 | 119.8 ± 0.0 | -0.4% |

## Separate 120 Hz GPU profiles

One 12-second active capture per renderer/layout. Command intervals are GPU envelopes for complete Vertex + Fragment buffers, not physical frame latency. The Active union uses all captured app stages, counts overlaps once, and can underestimate activity when intervals are missing. It excludes the compositor.

| Surface | Views | Renderer | Observed buffers/update | Command mean ms | Median ms | p95 ms | Complete / observed buffers | Observed Active union ms/update |
| --- | ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 152×88 | 60 | kh | 60.00 | 0.244 | 0.225 | 0.332 | 20474 / 28561 | 9.111 |
| 152×88 | 60 | swiftui | 1.00 | 1.218 | 1.497 | 1.738 | 1439 / 1439 | 1.187 |
| 320×200 | 15 | kh | 15.00 | 0.542 | 0.574 | 0.591 | 11511 / 21585 | 4.106 |
| 320×200 | 15 | swiftui | 13.25 | 0.295 | 0.201 | 0.871 | 13565 / 19070 | 1.389 |

The 60-view SwiftUI trace has one complete GPU command buffer per update for the entire grid. A KH buffer renders one mesh. Their command-buffer means must not be compared as if they represented the same number of views.


## Reproducibility

Primary runs: 44. All environments valid: True.

Executable SHA-256:

- `0faaa4152ad42873c2edb6965e4311b1572ee6a0eb7150ea3c2f9cb7e6022555`

Source tree SHA-256 (Sources + Example Swift):

- `7ce59adfdf279a4ff504d54c65bf200f7fb82b2323c5f18b38619359b46d44ad`
