# Documentation

Start with the root [README](../README.md) for installation, public API usage,
animation, debugging, and the example app.

- [Architecture](Architecture.md): rendering, geometry, color, and animation design.
- [Verification](Verification.md): tested configurations and runtime limitations.
- [Comparison gallery](Comparisons/README.md): identical-input SwiftUI/Metal renders.
- [Current adaptive renderer measurements](Benchmarks/Adaptive/README.md): current
  CPU, memory, GPU, and pixel-convergence evidence.
- [Contributor and release notes](Contributing.md): project layout, checks, and
  remaining release work.
- [Script guide](../Scripts/README.md): capture and analysis tools.

## Historical measurements

These reports preserve measurements of earlier implementations. Use the adaptive
report above when evaluating the current renderer.

- [Original benchmark sweep](Benchmarks/README.md)
- [Distinct randomized gradients](Benchmarks/Randomized/README.md)
- [Command-buffer batching](Benchmarks/Optimized/README.md)
- [Geometry-resolution experiments and SwiftUI observations](Benchmarks/Geometry/README.md)

Raw inputs, PNG captures, hashes, and analysis outputs are intentional research
artifacts. Keep them alongside their reports so results remain reproducible.
Large Instruments traces and local build products belong in ignored `DerivedData/`.
