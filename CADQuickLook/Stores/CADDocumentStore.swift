import Foundation
import Observation

@MainActor
@Observable
final class CADDocumentStore {
    var asset: CADModelAsset?
    var isLoading = false
    var loadingURL: URL?
    var loadingProgress: CADLoadProgress?
    var errorMessage: String?
    /// Incremented per open() so a slow earlier load cannot overwrite a newer one.
    private var loadGeneration = 0
    /// The load in flight; cancelled by close() and by a newer open(), which
    /// stops the import (or removes it from the import queue).
    private var loadTask: Task<Void, Never>?

    var representedURL: URL? { asset?.url }

    /// Drops the open model and abandons any load in flight. Called when the
    /// window closes: SwiftUI can keep a closed window's state alive, and
    /// with it hundreds of megabytes of mesh and B-Rep.
    func close() {
        loadGeneration += 1
        loadTask?.cancel()
        loadTask = nil
        asset = nil
        isLoading = false
        loadingURL = nil
        loadingProgress = nil
    }

    func open(_ url: URL) {
        let supported = Set(["step", "stp", "iges", "igs", "brep", "stl", "dxf"])
        guard supported.contains(url.pathExtension.lowercased()) else {
            errorMessage = "Choose a STEP, IGES, BREP, STL, or DXF file. Parasolid requires an optional commercial importer."
            return
        }

        isLoading = true
        loadingURL = url
        loadingProgress = nil
        loadGeneration += 1
        loadTask?.cancel()
        let generation = loadGeneration
        loadTask = Task {
            do {
                // One import at a time across the app; tessellation runs off
                // the main thread so the window stays responsive.
                let loaded = try await CADImportGate.run(whileWaiting: {
                    Task { @MainActor in
                        guard self.loadGeneration == generation else { return }
                        self.loadingProgress = .queued
                    }
                }) {
                    try await CADModelAsset.load(url: url) { progress in
                        Task { @MainActor in
                            guard self.loadGeneration == generation else { return }
                            self.loadingProgress = progress
                        }
                    }
                }
                guard loadGeneration == generation else { return }
                asset = loaded
                errorMessage = nil
            } catch is CancellationError {
                // Closed or superseded; nothing to report.
                guard loadGeneration == generation else { return }
            } catch {
                guard loadGeneration == generation else { return }
                errorMessage = error.localizedDescription
            }
            isLoading = false
            loadingURL = nil
            loadingProgress = nil
            loadTask = nil
        }
    }
}
