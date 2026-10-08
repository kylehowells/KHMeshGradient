# Contributing and release preparation

## Layout

| Directory | Contents |
| --- | --- |
| `Sources/KHMeshGradient` | Importable UIKit/Metal library and shader resource |
| `Tests/KHMeshGradientTests` | Simulator/device XCTest suite |
| `Example` | Checked-in example Xcode project and XcodeGen source |
| `Documentation` | Design, verification, comparisons, and benchmark evidence |
| `Scripts` | Capture, profiling, and analysis utilities |
| `DerivedData` | Ignored local builds, test results, and trace archives |

The library has no external package dependencies. Documentation and example
assets are outside the package target; consumers compile the library sources
and its Metal resource.

## Checks

Open `Example/KHMeshGradientExample.xcodeproj` and use the
`KHMeshGradientExample` scheme. Run Product → Test on a specific iOS Simulator
or paired device. Host-side `swift test` cannot exercise this UIKit package.
Build Release for an iOS device and both Catalyst architectures when changing
cross-platform code. The established results are in [Verification](Verification.md).

Keep public API comments and README examples current. Renderer changes should
retain animation, interruption, scrubbing, idle-submission, and GPU pixel checks.
Preserve comparison inputs; regenerate output sheets when rendering changes.

`Example/project.yml` is the source for the checked-in Xcode project. Regenerate
with XcodeGen after changing project configuration. Select your own signing team
locally or pass it through an `xcodebuild` setting; do not commit machine-specific
signing credentials, device identifiers, or absolute paths.

## Swift formatting

The checked-in `.swiftformat` matches the configuration used by Spherium's
KHComponents package. This formatting pass used SwiftFormat 0.62.1.
Run from the repository root:

```sh
swiftformat Sources Tests Example/Sources Package.swift --config .swiftformat
swiftformat Sources Tests Example/Sources Package.swift --config .swiftformat --lint
```

These paths cover library, tests, example, and package manifest while leaving
local build products alone. The configuration uses tabs, explicit `self`, and
next-line `else`, and preserves existing type annotations and constructor names.
It disables the rule that adds trailing closures; it does not automatically
convert existing trailing closures into named arguments.

## Local artifacts

Keep temporary exports, profiler traces, logs, and build products in
`DerivedData/`; it is ignored. Python environments and caches are also ignored.
Retained reports and Markdown notes belong under `Documentation/`. Keep root
`README.md`, `LICENSE`, `LICENSE-MIT`, `LICENSE-APACHE`, `Package.swift`, and
`AGENTS.md` in their conventional locations.
Do not remove recorded benchmark inputs merely because they were generated.

## Before the first public release

The MIT/Apache-2.0 dual-license texts and Swift package manifest are present.
The public repository is https://github.com/kylehowells/KHMeshGradient and `main`
is published. There is no version tag yet. Once the API scope is settled, tag a
semantic version that matches the intended stability and update the README's
branch dependency to use that released version.

Pre-iOS-18 runtime verification is still outstanding despite the iOS 15 deployment
target. Interactive animation uses public hooks whose UIKit registration behavior
is undocumented. Retain those limitations in release notes until verified.
The current performance workload animates geometry with fixed palettes; a
continually changing-palette workload has not yet been benchmarked.
