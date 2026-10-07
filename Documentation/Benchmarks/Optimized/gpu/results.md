# Separate GPU profiles

Five seconds of measured motion per renderer, same final Release executable and seed-42 input manifest. Metal System Trace excludes the system compositor. CPU and cadence during profiling do not contribute to the primary estimates.

| Renderer | Complete buffers | Buffers/update | Mean envelope ms | Median ms | p95 ms | Active union ms/update | Idle-before buffers |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| kh | 599 | 1.00 | 6.253 | 6.480 | 7.199 | 5.202 | 0 |
| swiftui | 599 | 1.00 | 1.798 | 1.766 | 1.996 | 1.714 | 0 |

Command envelopes span the first app vertex/fragment work to the last work for each buffer. Active union counts overlapping app Active stages once. Both scenes render 60 different palettes/initial geometries and independently phased motion, with matching hashes. GPU frequency/profiling effects can vary; these are single profiles, not repeated CPU/memory trials.

One initial KH export and one attached SwiftUI export crashed in xctrace and are excluded. The successful KH retry used a delayed construction phase; SwiftUI required an all-process recording, then the extractor filtered to the benchmark app. Both successful profiles cover the full measured active interval and contain complete stage pairs for every observed app buffer. Kernel-only signpost loss warnings do not contribute measurement data; phase bounds come from the fresh app JSON.

Fixture SHA-256: `da4587a967f8928822d7be348c1e2ba64ac129e75354ac336cca9728ce1bf72a`. Raw trace/XML files remain in ignored DerivedData; public files contain sanitized aggregate measurements only.
