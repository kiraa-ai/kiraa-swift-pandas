import Foundation

// `Bundle.module` is synthesized by SwiftPM for test targets that have
// resources. When the same test target is built from the XcodeGen-generated
// .xcodeproj, that synthesized accessor does not exist, so we polyfill it
// here. The `!SWIFT_PACKAGE` guard ensures SwiftPM continues to use its real
// `Bundle.module` (which carries the package-specific resource bundle name).
#if !SWIFT_PACKAGE
extension Foundation.Bundle {
    static var module: Bundle {
        Bundle(for: BundleModuleAnchor.self)
    }
}

/// Type whose owning bundle is the test bundle. Used solely to find the
/// bundle URL for `Bundle.module` in the Xcode build.
private final class BundleModuleAnchor {}
#endif
