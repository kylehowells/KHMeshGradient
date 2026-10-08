# Repository guidelines

- The library is UIKit-first, programmatic, and backed by a custom CAMetalLayer.
- Keep it independent of app-specific dependencies and of SwiftUI's iOS 18 MeshGradient.
- Use tabs, explicit self, parameter names for closure arguments, and manual view layout.
- Swift package sources live in Sources/KHMeshGradient; the iOS example lives in Example.
- Every new public API needs documentation and a representative example or preview.
- Test UIKit/Metal code on Simulator, not with host-side swift test.
- Open Example/KHMeshGradientExample.xcodeproj and use the KHMeshGradientExample scheme.
- Example/project.yml is the XcodeGen source; regenerate the checked-in Xcode project after changing it.
- Verify real onscreen animation and idle GPU submission counts, not just presentation values.
- Preserve the raw-input comparison fixtures. Rebuild comparison sheets after renderer changes.
- Do not claim pixel identity with SwiftUI or change tests merely to hide rendering differences.
- Do not commit DerivedData, result bundles, editor state, or machine-specific paths.
- Use the checked-in `.swiftformat` for Swift formatting; see Documentation/Contributing.md for the scoped format/lint commands.
