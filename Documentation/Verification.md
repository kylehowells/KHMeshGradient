# Verification

Verified on 6–7 October 2026 using Xcode 26.6.

| Check | Result |
| --- | --- |
| Example app build/run, iPad Pro Simulator, iOS 26.5 | Passed |
| XCTest suite, iOS 26.5 | 15 passed; no failures or skips |
| XCTest suite, iPhone SE Simulator, iOS 18.2 | 14 passed; no failures or skips |
| Standalone Swift package, generic iOS device, Release, deployment target 15.0 | Passed |
| Standalone Swift package, Mac Catalyst, deployment target 15.0 | Passed |
| Nine Metal/SwiftUI image comparisons and three debug pairs | Captured and inspected |
| Release example, M1 iPad Pro, iPadOS 18.6 | Built, installed, and exercised |

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

Pre-iOS-18 runtime testing and interactive
UIViewPropertyAnimator support remain outside the verified capability set.
This version explicitly documents UIViewPropertyAnimator as unsupported.
