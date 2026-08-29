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

/// The app window's Liquid Glass background. Mounted once behind every state
/// of `ContentView` so empty, loading and viewer screens share one backdrop.
struct CADGlassBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> CADGlassBackdrop {
        CADGlassBackdrop(host: .appWindow)
    }

    func updateNSView(_ view: CADGlassBackdrop, context: Context) {}
}
