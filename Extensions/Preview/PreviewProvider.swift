import AppKit
@preconcurrency import QuickLookUI

final class PreviewProvider: NSViewController, @MainActor QLPreviewingController {
    private let backdrop = CADGlassBackdrop(host: .previewPanel)
    private let viewer = CADViewerSurface()
    /// The import in flight. Quick Look reuses the controller for the next
    /// file and dismisses it while loads can still be running; cancelling
    /// stops the import instead of letting it finish into a hidden panel.
    private var loadTask: Task<Void, Never>?
    /// Incremented per load so a cancelled load's queued progress hops
    /// don't overwrite the next file's status.
    private var loadGeneration = 0

    override func loadView() {
        backdrop.frame = NSRect(x: 0, y: 0, width: 960, height: 720)
        backdrop.contentView = viewer
        viewer.showsBuildStamp = true
        viewer.showsFileName = false
        view = backdrop
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // Keyboard shortcuts (F, arrows, P, E) without clicking first.
        viewer.focusViewer()
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        loadTask?.cancel()
        loadTask = nil
    }

    isolated deinit {
        loadTask?.cancel()
    }

    func preparePreviewOfFile(at url: URL) async throws {
        loadTask?.cancel()
        loadGeneration += 1
        let generation = loadGeneration
        preferredContentSize = NSSize(width: 960, height: 720)
        viewer.showLoading("Opening \(url.lastPathComponent)")
        // Tessellation can take seconds on large assemblies; keep it off the
        // extension's main thread so Quick Look (and other previews queued
        // behind this one) stay responsive. Small files finish before Quick
        // Look shows the panel; large ones show their progress in the panel.
        let viewer = self.viewer
        loadTask = Task { @MainActor [weak self] in
            do {
                let asset = try await CADModelAsset.load(url: url) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self, self.loadGeneration == generation else { return }
                        viewer.showLoading("\(progress.title)…", fraction: progress.fraction)
                    }
                }
                guard let self, self.loadGeneration == generation else { return }
                viewer.display(asset)
            } catch is CancellationError {
                // Dismissed or replaced by the next file.
            } catch {
                guard let self, self.loadGeneration == generation else { return }
                viewer.showLoading(error.localizedDescription)
            }
        }
    }
}
