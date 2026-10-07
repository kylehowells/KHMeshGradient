# Randomized stress-test results

Three fresh trials per renderer/variant. Random trials use seeds 42, 2026, and 8675309; palettes and initial interior geometry differ for all 60 views. Each seed is paired exactly between renderers. Variation includes input variation across seeds. All metrics below come from unprofiled runs.

| Inputs | Renderer | Trials | CPU ms/update | Extra app MiB | Total app MiB | Updates/s | p95 callback gap ms |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| randomized-per-view | kh | 3 | 23.92 ± 0.39 | 121.66 ± 2.67 | 128.53 ± 2.76 | 45.2 ± 0.6 | 23.40 ± 0.06 |
| randomized-per-view | swiftui | 3 | 3.34 ± 0.02 | 73.73 ± 5.33 | 80.55 ± 5.30 | 118.4 ± 0.9 | 8.42 ± 0.00 |
| shared-fixture | kh | 3 | 24.04 ± 0.15 | 121.83 ± 2.08 | 128.59 ± 2.01 | 44.9 ± 0.2 | 23.50 ± 0.14 |
| shared-fixture | swiftui | 3 | 3.35 ± 0.05 | 74.13 ± 1.55 | 80.86 ± 1.59 | 118.7 ± 0.8 | 8.42 ± 0.00 |

## Separate randomized GPU profiles

Seed 42, one 12-second active profile per renderer. GPU command envelopes exclude the compositor. A command buffer can render many meshes; command means have different scopes. The union counts overlapping captured app Active stages once and can underestimate missing intervals. Profiled CPU and cadence do not replace the unprofiled values above.

| Renderer | Unique inputs | Buffers/update | Command mean ms | Median ms | p95 ms | Complete / observed buffers | Observed Active union ms/update | Idle-before buffers |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| kh | 60 | 60.00 | 0.249 | 0.229 | 0.337 | 20268 / 28560 | 9.189 | 0 |
| swiftui | 60 | 1.00 | 1.811 | 1.788 | 2.015 | 1439 / 1439 | 1.725 | 0 |

Validated renderer pairs: 6. Executable SHA-256: `de28b15ce024b5c4295e925024354735bf74a1ae15ea2cfbe2fbde44ba3bd6b3`.

Source tree SHA-256: `fc2b29c4c67662ec51d55c8edec31b7cd82755f608ab2e8ef8ca1cb84a938f52`.
