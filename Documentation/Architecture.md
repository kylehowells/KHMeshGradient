# Rendering architecture

`KHMeshGradientView` has a standard UIKit initializer and mutable configuration.
Its backing layer is `KHMeshGradientLayer`, a `CAMetalLayer` subclass. The release
renderer uses UIKit, QuartzCore, and Metal only. SwiftUI is used in debug previews
and in the example's reference panels.

## Data and interpolation

The view retains UIKit configuration. Effective positions, handles, and resolved
colors are written into CALayer KVC keys such as `mesh_point_4` and
`mesh_color_4`. Layer presentation copies contain the interpolated values.

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
does not cancel the redraw driver of a longer animation. The driver does not
participate in UIKit completion bookkeeping. It has no visible value and does
not define a separate clock, timer, or fixed frame rate.

The renderer reads an immutable snapshot from the presentation layer and compares
it with its last submitted snapshot. Identical snapshots, including any extra
end-of-animation invalidation, produce no additional GPU submission.

`UIViewPropertyAnimator` supplies an opaque CAAction that retains the native
property's key path. Forwarding it would animate the background instead of the
mesh. This version suppresses that action and documents interactive animators
as unsupported. No private APIs or runtime introspection are used.

## Geometry and color

Automatic geometry estimates cardinal handles using neighboring positions.
Explicit geometry uses the caller's four handles at each vertex. Four shared
boundary curves define each bicubic Coons patch. Adjacent patches share their
boundary curves exactly. Interior color interpolation is bicubic, with zero
outer color derivatives and monotonic tangents at interior color extrema.
Unsmoothed colors use bilinear interpolation independently of patch geometry.

The CPU uploads 16 position controls and 16 color controls per patch. The vertex
shader generates a regular parameter-space triangle grid using vertex and
instance IDs and evaluates the bicubic surfaces. The fragment shader converts
the interpolated color back from the selected interpolation space and writes
premultiplied-alpha sRGB. Positions and colors need no per-frame CPU tessellation.

The mesh pass replaces pixels inside the mesh instead of blending against the
mesh background; this preserves SwiftUI's outside-only background semantics.
Debug overlays use a separate premultiplied blending pipeline.

## Presentation and resources

Pipelines and the command queue are shared and initialized once. Xcode compiles
the bundled Metal source into the package's default metallib. Source compilation
is a fallback for packaging workflows that copy the source resource instead.

The model layer owns GPU work. Presentation copies share the renderer and copy
non-animated configuration in `init(layer:)`; they do not create devices or
pipelines. Drawable dimensions follow view bounds and display scale.

For UIKit synchronization, `presentsWithTransaction` is enabled. Commands are
committed, `waitUntilScheduled()` is called, and the drawable is presented
directly. Onscreen rendering does not wait for GPU completion. Offscreen image
export intentionally waits before reading a shared texture.

The last drawable remains displayed during idle periods. There is no permanent
CADisplayLink or CAMetalDisplayLink. Missing drawables trigger a delayed,
coalesced retry only while rendering is enabled. No busy-wait loop is used.

## References

- [CALayer's KVC container support](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/CoreAnimation_guide/Key-ValueCodingExtensions/Key-ValueCodingExtensions.html)
- [needsDisplay(forKey:)](https://developer.apple.com/documentation/quartzcore/calayer/needsdisplay(forkey:))
- [CAMetalLayer](https://developer.apple.com/documentation/quartzcore/cametallayer)
- [Transaction-synchronized presentation](https://developer.apple.com/documentation/quartzcore/cametallayer/presentswithtransaction)
- [SwiftUI MeshGradient](https://developer.apple.com/documentation/swiftui/meshgradient)
- [Animating Metal content through Core Animation](https://noahgilmore.com/blog/coreanimation-metal)
