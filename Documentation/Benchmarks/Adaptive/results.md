# Adaptive renderer measurements

Three fresh Release processes per row, same M1 iPad/iPadOS 18.6, requested 120 Hz, distinct seed-42 meshes. Current KH and SwiftUI pairs use one executable. Before uses the preserved geometry-sweep fixed-48 executable; input hashes match the current 60-view case. All runs retained; no thermal/power/visibility/interruptions/GPU errors. KH idle-after submits zero frames.

| Views / renderer | CPU ms/update | Extra MiB | Updates/s | KH presentation/s | KH GPU batch envelope ms |
| --- | ---: | ---: | ---: | ---: | ---: |
| 15 / Adaptive kh | 2.28 ± 0.01 | 56.16 ± 0.12 | 119.81 ± 0.00 | 119.93 ± 0.00 | 2.20 ± 0.01 |
| 15 / Adaptive swiftui | 3.86 ± 0.00 | 91.01 ± 0.19 | 119.81 ± 0.00 | — | — |
| 60 / Adaptive kh | 4.90 ± 0.00 | 50.70 ± 0.31 | 119.81 ± 0.00 | 119.93 ± 0.00 | 1.85 ± 0.01 |
| 60 / Adaptive swiftui | 3.36 ± 0.01 | 73.06 ± 5.19 | 119.31 ± 0.57 | — | — |
| 60 / Before kh | 4.48 ± 0.09 | 68.42 ± 0.22 | 119.81 ± 0.00 | 119.93 ± 0.00 | 6.42 ± 0.06 |

60-view cells are 152×88 pt; 15-view cells are 320×200 pt, both at scale 2. CPU is whole-process consumed time; callbacks are not SwiftUI presentation proof. KH diagnostics allocate completed command-buffer envelopes across participating views; they are not isolated per-view costs. The compositor is excluded.

## Separate GPU profiles

| Renderer, 60 views | Profiles | Mean envelope ms | Active union ms/update | Vertex active ms/update | Fragment active ms/update |
| --- | ---: | ---: | ---: | ---: | ---: |
| kh | 1 | 1.894 (single profile) | 1.317 (single profile) | 0.323 (single profile) | 1.214 (single profile) |
| swiftui | 2 | 1.801 ± 0.001 | 1.718 ± 0.001 | 0.267 ± 0.002 | 1.453 ± 0.000 |

Five seconds of motion per profile, same all-process Metal System Trace mode, filtered to app depth-zero Active stages. Additional captures repeatedly failed export due to system-daemon timeline errors; failed captures are excluded. Single-profile KH trace repeat variation is unknown. Three independent unprofiled KH GPU-diagnostic trials are available above. Stage activity can overlap. All observed buffers have complete Vertex/Fragment pairs, one buffer/update and zero idle-before buffers. Profiling CPU/cadence are excluded from primary trials; GPU frequency and capture effects can vary. Trace envelopes and command-buffer diagnostic envelopes have different boundaries and are presented separately. Raw traces/XML remain in ignored DerivedData.
