import AppKit
@preconcurrency import QuickLookUI

final class PreviewProvider: NSViewController, @MainActor QLPreviewingController {
    private let viewer = CADViewerSurface()

    override func loadView() {
        viewer.frame = NSRect(x: 0, y: 0, width: 960, height: 720)
        view = viewer
    }

    func preparePreviewOfFile(at url: URL) async throws {
        let asset = try CADModelAsset(url: url)
        viewer.display(asset)
        preferredContentSize = NSSize(width: 960, height: 720)
    }
}
