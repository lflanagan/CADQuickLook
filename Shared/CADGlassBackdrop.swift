import AppKit

/// The single Liquid Glass surface every CADQuickLook window sits on: the app
/// window in all of its states (empty, loading, viewing) and the Quick Look
/// preview panel. Hosts mount it once and never toggle it, so the background
/// looks the same no matter where, or whether, a model is open.
@MainActor
final class CADGlassBackdrop: NSGlassEffectView {
    enum Host {
        /// The Quick Look panel: the glass draws its own rounded corners.
        case previewPanel
        /// The app window clips its own corners, so the glass runs edge to edge.
        case appWindow
    }

    private let host: Host

    init(host: Host) {
        self.host = host
        super.init(frame: .zero)
        style = .regular
        cornerRadius = host == .previewPanel ? 22 : 0
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureWindow()
        // Hosts (SwiftUI, Quick Look) may restyle the window after attaching
        // the view; re-apply once they are done.
        Task { @MainActor [weak self] in
            self?.configureWindow()
        }
    }

    /// Makes the window see-through so the glass samples what's behind it
    /// instead of an opaque window fill.
    private func configureWindow() {
        guard let window else { return }
        window.isOpaque = false
        window.backgroundColor = .clear

        guard host == .appWindow else { return }
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
    }
}
