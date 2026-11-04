import SwiftUI

/// Embeds the shared AppKit viewer in SwiftUI.
struct CADViewerSurfaceView: NSViewRepresentable {
    let asset: CADModelAsset

    func makeNSView(context: Context) -> CADViewerSurface {
        let view = CADViewerSurface()
        view.onOpenSettings = Self.openSettings
        view.display(asset)
        return view
    }

    func updateNSView(_ view: CADViewerSurface, context: Context) {
        guard view.representedURL != asset.url else { return }
        view.display(asset)
    }

    /// Runs the app menu's "Settings…" item (⌘,), which SwiftUI's Settings
    /// scene owns. AppKit has no public call that opens that scene directly.
    @MainActor
    private static func openSettings() {
        guard let appMenu = NSApp.mainMenu?.items.first?.submenu,
              let index = appMenu.items.firstIndex(where: {
                  $0.keyEquivalent == "," && $0.keyEquivalentModifierMask == .command
              }) else { return }
        appMenu.performActionForItem(at: index)
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
