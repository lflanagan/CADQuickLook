import Foundation
import Observation

@MainActor
@Observable
final class CADDocumentStore {
    var asset: CADModelAsset?
    var isLoading = false
    var errorMessage: String?

    var representedURL: URL? { asset?.url }

    func open(_ url: URL) {
        let supported = Set(["step", "stp", "iges", "igs", "brep", "stl"])
        guard supported.contains(url.pathExtension.lowercased()) else {
            errorMessage = "Choose a STEP, IGES, BREP, or STL file. Parasolid requires an optional commercial importer."
            return
        }

        isLoading = true
        defer { isLoading = false }
        do {
            asset = try CADModelAsset(url: url)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
