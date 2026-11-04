import Foundation

/// Identifies the running build so a stale install is obvious at a glance.
enum CADBuildInfo {
    /// e.g. "v0.9.0".
    static let stamp: String = {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        return "v\(version)"
    }()
}
