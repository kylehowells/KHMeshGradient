# Verification

Verified on 6–8 October 2026 using Xcode 26.6. Current renderer checks include
adaptive geometry and per-fragment color; historical measurements below retain
their original implementation context.

| Check | Result |
| --- | --- |
| Example app build/run, iPad Pro Simulator, iOS 26.5 | Passed |
| XCTest suite, iOS 26.5 | 31 passed; no failures or skips |
| XCTest suite, iPhone SE Simulator, iOS 18.2 | 31 passed; no failures or skips |
| Standalone Swift package, generic iOS device, Release, deployment target 15.0 | Passed |
| Standalone Swift package, Mac Catalyst arm64/x86_64, deployment target 15.0 | Passed |
| Nine Metal/SwiftUI image comparisons and three debug pairs | Captured and inspected |
| Release example, M1 iPad Pro, iPadOS 18.6 | Built, installed, and exercised |
| Release XCTest suite, physical M1 iPad Pro, iPadOS 18.6 | 31 passed; no failures or skips |

Runtime tests verify actual Metal pixels, premultiplied transparency, background
fill, source switching, invalid-configuration recovery, patch continuity, all
interpolation/debug modes, dynamic UIKit colors, point/color/handle animations,
springs, interruption, immediate changes, completion callbacks, rendering
suspension, and unchanged idle GPU submission counts.

Onscreen animation tests check both presentation values and GPU submission
counts. This catches the case where layer values interpolate while the Metal
surface remains static.

The new diagnostics test also verifies that an ordinary non-animated point
assignment changes the submitted frame, that metrics are opt-in, and that
resetting/disabling them isolates counters. The benchmark exposed a stale
presentation-layer snapshot during ordinary setters; the renderer now uses
model values when no mesh animation is active.

See [physical-device benchmarks](Benchmarks/README.md) for repeated memory,
whole-process CPU, GPU, idle, and 120 Hz stress measurements. Simulator captures
validate that all 60 SwiftUI cells are visible and change across the run; those
captures are separate from physical-device performance measurements.
Post-run screenshots from the benchmark iPad additionally verify all 60 views
onscreen for both renderers. All 44 primary and 12 control trials use the same
Release executable, remain at nominal thermal state, have Low Power Mode off,
and have no active-app interruptions. GPU profiles are separate runs.

Interactive UIViewPropertyAnimator tests verify multi-property scrubbing,
real Metal color pixels, zero GPU submissions during a pause longer than the
original duration, resumed rendering, reversal with replacement timing,
springs/explicit handles, `.start`/`.current` model restoration, native alpha in
the same animator, overlapping animators, subsequent legacy block animation,
added animation blocks, and dynamic UIColor restoration. The example adds a
UIKit scrub slider and resume button. This bridge depends on undocumented UIKit
action-registration behavior through public APIs. Pre-iOS-18 runtime testing
remains outside the verified capability set.

The randomized benchmark extension builds in Release for the physical iPad and
in Debug for Simulator. Its 12 fresh-process trials validate exact matching
per-view inputs between renderers, 60 unique randomized fixtures per scene,
consistent viewport/build hashes, nominal thermal state, and no interruptions.
The library renderer source is unchanged. The first simulator suite run observed
one delayed final submission in the idle-animation test; the focused rerun and
then the full 15-test suite passed unchanged. Physical idle-after phases continue
to report zero submissions.

The batched optimization adds shared native render targets, indexed triangles,
completion-safe reusable upload buffers, and cached static model/color data.
The 60-view randomized scene now records one command buffer and eight render
passes per update, preserving the original 48 subdivisions. New tests cover
all eight fragment output slots with distinct palettes, transparency/backgrounds,
debug blending, and mixed target sizes; batched readback pixels match independent
renders exactly. Multiple animated views coalesce and scrub together, then submit
no idle work. All 29 original export images were regenerated with zero changed
before/after pixels. See [optimization evidence](Benchmarks/Optimized/README.md).

The adaptive renderer now selects geometry from a framebuffer-pixel second-
derivative bound and evaluates cubic color per fragment. New GPU tests verify
analytic colors on a single-cell patch, all interpolation spaces/transparency,
full-precision fallback for values beyond half range, mixed curvature, work
limits, error-target samples, animated selection and policy changes while paused,
and actual debug diagonals. Existing animation, MRT pixel-isolation, and idle
tests pass unchanged. Catalyst uses raw half bits on arm64 and the float
specialization on Intel, avoiding unsupported Swift Float16 SIMD.

The ordinary nine-pair comparison/debug sheets were rebuilt with the new shader.
SwiftUI references remain byte-identical. A separate physical-device matrix has
360 actual renders and preserved input/image hashes. Repeated current CPU/memory
trials cover two viewport sizes, with three pairs each; all are retained and valid.
GPU diagnostics have three KH trials. Instruments retained one KH and two SwiftUI
app-only profiles; further all-process exports failed on unrelated daemon
timelines, so trace repeat variation for KH remains unknown. See the
[current adaptive evidence](Benchmarks/Adaptive/README.md).
