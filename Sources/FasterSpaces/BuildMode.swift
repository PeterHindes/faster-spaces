import Foundation

/// Compile-time build mode. Release builds are produced with
/// `scripts/build.sh --release` (or `FASTERSPACES_BUILD_MODE=release`) and
/// define `FASTERSPACES_RELEASE`. Development builds keep the log file and
/// diagnostics UI.
enum BuildMode {
    static let isRelease: Bool = {
        #if FASTERSPACES_RELEASE
        return true
        #else
        return false
        #endif
    }()

    static let name = isRelease ? "release" : "development"
}
