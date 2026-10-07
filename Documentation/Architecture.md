# Rendering architecture

`KHMeshGradientView` has a standard UIKit initializer and mutable configuration.
Its backing layer is `KHMeshGradientLayer`, a `CAMetalLayer` subclass. The release
renderer uses UIKit, QuartzCore, and Metal only. SwiftUI is used in debug previews
and in the example's reference panels.

## Data and interpolation

The view retains UIKit configuration. Ordinary changes use a cached immutable
model snapshot, avoiding per-vertex KVC reads/writes and repeated UIColor/CGColor
conversion. Color resolution is invalidated by color or trait changes; color
control nets are cached until their inputs or interpolation settings change.
Automatic handles are rebuilt when geometry changes.

Before an animation begins, the layer seeds CALayer KVC keys such as
`mesh_point_4` and `mesh_color_4` from the preceding model snapshot. It then writes
changed values. Presentation copies interpolate those keys; unchanged resolved
colors can reuse the model's converted components. A newly seeded key may not
exist in an older presentation copy, so action lookup falls back to the model.
The initial UIKit action is consumed rather than abandoned, preserving property
animator completion bookkeeping.

For regular animation blocks, `action(for:forKey:)` requests UIKit's
`backgroundColor` animation action, copies the returned `CABasicAnimation` or
`CASpringAnimation`, retargets the key path, and sets its starting value from
the presentation layer. UIKit's timing, delay, spring constants, frame-rate
hints, and completion delegate are preserved. Initialization and disabled
animation return an NSNull action.

Arbitrary KVC keys alone did not consistently cause redraws in runtime tests.
The layer also declares `@NSManaged var redrawProgress: CGFloat` and returns true
for its `needsDisplay(forKey:)`. Adding a mesh animation adds a separate
redisplay animation on that declared property, with the original animation's
timeline. These animations have independent keys so a short later animation
does not cancel the redraw driver of a longer animation. For ordinary UIView animation blocks, the driver does not
participate in UIKit completion bookkeeping. It has no visible value and does
not define a separate clock, timer, or fixed frame rate.

The renderer reads an immutable snapshot from the presentation layer while mesh
animations are active, and from the model layer for ordinary property updates.
Reading a stale presentation copy during a non-animated update can otherwise
suppress a changed frame. It compares the snapshot with its last submitted
snapshot. Identical snapshots, including any extra
end-of-animation invalidation, produce no additional GPU submission.

`UIViewPropertyAnimator` supplies a CAAction rather than a directly copyable
animation. `MeshAnimationAction` runs that action on the mesh layer. While it
runs, the layer's public `add(_:forKey:)` override retargets the **original**
CABasicAnimation in place, replacing its key path, endpoints, and storage key
before passing it to `super.add`. A copied animation would leave UIKit tracking
the original background-color animation. Mutating the original before UIKit
registers it lets UIKit subsequently pause, scrub, reverse, and resume the custom
key. Native helper animations pass through untouched.

Each mesh action also runs a second native action for `redrawProgress`, stored
under its own `redraw_<mesh key>` key. UIKit manages that driver's timeline too;
it cannot expire on the original wall-clock deadline during a long pause, and a
short concurrent animator cannot stop a longer animator's driver. A custom
CAAnimation KVC marker survives animation copying/re-addition and distinguishes
these managed animations from ordinary block animations. Snapshot equality still
prevents GPU submissions while paused.

When UIKit restores the model layer at `.start` or `.current`, `setValue(_:forKey:)`
notifies the view to synchronize its stored positions, handles, colors, and
background without triggering a new configuration update. Original dynamic
UIColor sources are retained for animated color restoration, so cancellation
preserves subsequent trait-dependent resolution.

This relies on experimentally verified UIKit action-registration behavior;
Apple documents the hooks, but does not promise that its native animation action
can be repurposed this way. There are no private selectors, class-name checks,
ivar accesses, swizzling, or runtime introspection in the shipped implementation.
Regression tests exercise iOS 18.2 and 26.5 Simulator and a physical M1 iPad
running iPadOS 18.6 in Release. iOS 15 remains the deployment target,
but pre-iOS-18 runtimes are unverified.

## Geometry and color

Automatic geometry estimates cardinal handles using neighboring positions.
Explicit geometry uses the caller's four handles at each vertex. Four shared
boundary curves define each bicubic Coons patch. Adjacent patches share their
boundary curves exactly. Interior color interpolation is bicubic, with zero
outer color derivatives and monotonic tangents at interior color extrema.
Unsmoothed colors use bilinear interpolation independently of patch geometry.

The CPU uploads separate position and color buffers: 16 float4 geometry controls
and 16 mixed-basis color coefficients per patch. Boundary vectors use stack SIMD
matrices. Color coefficients convert one axis to a power basis for Horner
evaluation and retain Bernstein controls in the other to reduce cancellation.
Opaque device colors use eight-byte packed half4 coefficients with 16-bit integer
storage on arm64; translucent, perceptual/linear, out-of-half-range inputs, and
Intel Catalyst use float4. Metal function constants specialize the pipelines so
unused precision/color-conversion paths have no runtime branch. Opaque alpha is
exactly one. No dithering or private framework code is used.

The vertex shader evaluates only position and forwards UV and a flat patch ID.
The fragment shader evaluates the complete color surface at that UV, converts
from the interpolation space if needed, and writes premultiplied sRGB. Color
sampling is independent of geometry density; UV approximation still depends
on geometry. No per-frame CPU vertex tessellation is required.

Zero subdivisions selects adaptive geometry. Bounds on both pure second
derivatives and the mixed derivative are computed in framebuffer pixels. For
each patch, the triangle position error estimate is `(uu + vv + 2*uv)/(8*n*n)`.
The maximum across patches determines a shared power-of-two density, targeting
`maximumGeometryError` (0.5 pixels by default). Including the mixed derivative
catches nonlinear parameter maps even with straight edges. Density is limited
to 128 and 65,536 cells across a mesh; fixed positive subdivisions bypass the
automatic error target/cell budget. Uniform density prevents cracks on shared
patch edges. Selection uses current presentation geometry during animations and
current texture dimensions after resizing or display-scale changes.

The tessellation overlay draws the actual selected cell edges and diagonals;
mesh/handle modes retain smooth boundary curves and control-point markers.

The mesh pass replaces pixels inside the mesh instead of blending against the
mesh background; this preserves SwiftUI's outside-only background semantics.
Debug overlays use a separate premultiplied blending pipeline.

## Presentation and resources

The command queue and pipeline cache are shared. Pipeline variants select one
color attachment, with writes to other attachments disabled. Their cache is
bounded to 32 states across output targets and color precision; the shared
triangle-index cache retains at most eight grids.
Per-command upload arenas use aligned regions in reusable shared buffers. Buffers
return to the locked pool only after GPU completion; cached idle buffers are
bounded to 4 MiB, separately from in-flight GPU-owned buffers. Xcode compiles
the bundled Metal source into the package's default metallib. Source compilation
is a fallback for packaging workflows that copy the source resource instead.

The model layer owns GPU work. Presentation copies share the renderer and copy
non-animated configuration in `init(layer:)`; they do not create devices or
pipelines. Drawable dimensions follow view bounds and display scale.

A weak registry tracks model layers. `setNeedsDisplay()` records library-owned
dirtiness because Core Animation may clear its own display flags before calling
`display()`. The first changed layer gathers other dirty or actively animating
layers; unchanged snapshots and suspended/hidden/detached layers are skipped.
Subsequent display callbacks see the already submitted snapshot and skip drawing.

All changed views share one command buffer. Compatible drawable sizes share a
render pass with up to eight independent color attachments on supported GPU
families; unknown families use one target. Each mesh draw selects its target
through the fragment output and pipeline write masks. Every view keeps its own
framebuffer-only CAMetalLayer texture, background clear, debug blending, clipping,
and UIKit composition. There is no shared atlas or texture-copy pass.

For UIKit synchronization, `presentsWithTransaction` is enabled. The batch is
committed inside the original display transaction, `waitUntilScheduled()` is
called once, and all drawables are presented. No additional transaction flush,
run-loop observer, timer, or display link is installed. Triple buffering is kept:
a device experiment with two drawables reduced this 120 Hz workload to 60 Hz.
Onscreen rendering does not wait for GPU completion. Offscreen image export
intentionally waits before reading a shared texture.

The last drawable remains displayed during idle periods. There is no permanent
CADisplayLink or CAMetalDisplayLink. Missing drawables trigger a delayed,
coalesced retry only while rendering is enabled. No busy-wait loop is used.

## Opt-in measurement

`collectsRenderingStatistics` enables aggregate CPU wall-time, completed Metal
command-buffer GPU-time, and drawable-presentation counters. It defaults to false.
`commandBufferCount` and `renderPassCount` allocate fractional contributions to
each participating view; summing over all enabled views gives submission counts.
Shared encoding setup and scheduling wait are allocated across participants.
GPU command envelopes are likewise divided equally among participating views,
rather than attributing the entire batch duration to every view. These are
allocations, not isolated timings of individual meshes. `gpuFrameCount` counts
this view's draws with completed timing samples, not independent command buffers.
The system compositor remains outside their scope. GPU callbacks use a locked store; resetting replaces the store so old in-flight
completions cannot contaminate a new measurement. No per-frame sample arrays are
retained by the library. The example benchmark separately samples whole-process
CPU and physical footprint for both renderers. Its display link exists only in
benchmark mode and is invalidated when a run finishes.

## References

- [Metal command-buffer best practices](https://developer.apple.com/library/archive/documentation/3DDrawing/Conceptual/MTLBestPracticesGuide/CommandBuffers.html)
- [Metal render-target limits](https://developer.apple.com/metal/feature-sets/)

- [UIViewPropertyAnimator](https://developer.apple.com/documentation/uikit/uiviewpropertyanimator)
- [CALayer.add(_:forKey:)](https://developer.apple.com/documentation/quartzcore/calayer/add(_:forkey:))
- [CAAction.run(forKey:object:arguments:)](https://developer.apple.com/documentation/quartzcore/caaction/run(forkey:object:arguments:))

- [CALayer's KVC container support](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/CoreAnimation_guide/Key-ValueCodingExtensions/Key-ValueCodingExtensions.html)
- [needsDisplay(forKey:)](https://developer.apple.com/documentation/quartzcore/calayer/needsdisplay(forkey:))
- [CAMetalLayer](https://developer.apple.com/documentation/quartzcore/cametallayer)
- [Transaction-synchronized presentation](https://developer.apple.com/documentation/quartzcore/cametallayer/presentswithtransaction)
- [SwiftUI MeshGradient](https://developer.apple.com/documentation/swiftui/meshgradient)
- [Animating Metal content through Core Animation](https://noahgilmore.com/blog/coreanimation-metal)
