import AppKit
@preconcurrency import QuickLookUI

final class PreviewProvider: NSViewController, @MainActor QLPreviewingController {
    private let backdrop = CADGlassBackdrop(host: .previewPanel)
    private let viewer = CADViewerSurface()

    override func loadView() {
        backdrop.frame = NSRect(x: 0, y: 0, width: 960, height: 720)
        backdrop.contentView = viewer
        viewer.showsBuildStamp = true
        view = backdrop
    }

    func preparePreviewOfFile(at url: URL) async throws {
        preferredContentSize = NSSize(width: 960, height: 720)
        viewer.showLoading("Opening \(url.lastPathComponent)")
        // Tessellation can take seconds on large assemblies; keep it off the
        // extension's main thread so Quick Look (and other previews queued
        // behind this one) stay responsive. Small files finish before Quick
        // Look shows the panel; large ones show their progress in the panel.
        let viewer = self.viewer
        Task { @MainActor in
            do {
                let asset = try await Task.detached(priority: .userInitiated) {
                    try CADModelAsset(url: url) { progress in
                        Task { @MainActor in
                            viewer.showLoading("\(progress.title)…", fraction: progress.fraction)
                        }
                    }
                }.value
                viewer.display(asset)
            } catch {
                viewer.showLoading(error.localizedDescription)
            }
        }
    }
}
