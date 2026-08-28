import SwiftUI

/// Embeds the shared AppKit viewer in SwiftUI.
struct CADViewerSurfaceView: NSViewRepresentable {
    let asset: CADModelAsset

    func makeNSView(context: Context) -> CADViewerSurface {
        let view = CADViewerSurface()
        view.display(asset)
        return view
    }

    func updateNSView(_ view: CADViewerSurface, context: Context) {
        guard view.representedURL != asset.url else { return }
        view.display(asset)
    }
}
