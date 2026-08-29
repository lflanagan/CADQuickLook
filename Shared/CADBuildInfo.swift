import Foundation

/// Identifies the running build so a stale install is obvious at a glance.
enum CADBuildInfo {
    /// e.g. "v0.2.0 · 2026-08-29 14:07", from the executable's link time.
    static let stamp: String = {
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let linkDate = bundle.executableURL
            .flatMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let date = linkDate.map(formatter.string(from:)) ?? "unknown"
        return "v\(version) · \(date)"
    }()
}
