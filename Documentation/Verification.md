# Verification

Verified on 6 October 2026 using Xcode 26.6.

| Check | Result |
| --- | --- |
| Example app build/run, iPad Pro Simulator, iOS 26.5 | Passed |
| XCTest suite, iOS 26.5 | 14 passed; no failures or skips |
| XCTest suite, iPhone SE Simulator, iOS 18.2 | 14 passed; no failures or skips |
| Standalone Swift package, generic iOS device, Release, deployment target 15.0 | Passed |
| Standalone Swift package, Mac Catalyst, deployment target 15.0 | Passed |
| Nine Metal/SwiftUI image comparisons and three debug pairs | Captured and inspected |

Runtime tests verify actual Metal pixels, premultiplied transparency, background
fill, source switching, invalid-configuration recovery, patch continuity, all
interpolation/debug modes, dynamic UIKit colors, point/color/handle animations,
springs, interruption, immediate changes, completion callbacks, rendering
suspension, and unchanged idle GPU submission counts.

Onscreen animation tests check both presentation values and GPU submission
counts. This catches the case where layer values interpolate while the Metal
surface remains static.

Pre-iOS-18 runtime testing, physical-device profiling, and interactive
UIViewPropertyAnimator support remain outside the verified capability set.
This version explicitly documents UIViewPropertyAnimator as unsupported.
