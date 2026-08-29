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

    var representedURL: URL? { asset?.url }

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
        let generation = loadGeneration
        Task {
            do {
                // Tessellation runs off the main thread so the window stays responsive.
                let loaded = try await Task.detached(priority: .userInitiated) {
                    try CADModelAsset(url: url) { progress in
                        Task { @MainActor [weak self] in
                            guard let self, self.loadGeneration == generation else { return }
                            self.loadingProgress = progress
                        }
                    }
                }.value
                guard loadGeneration == generation else { return }
                asset = loaded
                errorMessage = nil
            } catch {
                guard loadGeneration == generation else { return }
                errorMessage = error.localizedDescription
            }
            isLoading = false
            loadingURL = nil
            loadingProgress = nil
        }
    }
}
