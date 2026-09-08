import AppKit
import SwiftUI

@MainActor
final class CADApplicationDelegate: NSObject, NSApplicationDelegate {
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        filenames.map(URL.init(fileURLWithPath:)).forEach(CADWindowRouter.shared.open)
        sender.reply(toOpenOrPrint: .success)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach(CADWindowRouter.shared.open)
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }
}

/// Routes file opens to a window: the key window's document when it is
/// empty (or the "new window" setting is off), otherwise a new window.
/// Windows register themselves as they become key.
@MainActor
final class CADWindowRouter {
    static let shared = CADWindowRouter()

    /// Set by any window's ContentView; SwiftUI's openWindow works from any of them.
    var openWindow: ((URL) -> Void)?
    private(set) weak var keyStore: CADDocumentStore?
    private var pending: [URL] = []

    func register(_ store: CADDocumentStore) {
        keyStore = store
        drain()
    }

    func open(_ url: URL) {
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        guard let keyStore else {
            pending.append(url)
            return
        }
        if keyStore.asset != nil || keyStore.isLoading, CADPreferences.opensFilesInNewWindow, let openWindow {
            openWindow(url)
        } else {
            keyStore.open(url)
        }
    }

    private func drain() {
        guard keyStore != nil, !pending.isEmpty else { return }
        let urls = pending
        pending.removeAll()
        urls.forEach(open)
    }
}

@main
struct CADQuickLookApp: App {
    @NSApplicationDelegateAdaptor(CADApplicationDelegate.self) private var appDelegate
    @State private var updater = UpdaterController()

    var body: some Scene {
        // One document per window; a URL value opens that file in a new window.
        WindowGroup(for: URL.self) { $url in
            ContentView(initialURL: url)
                .frame(minWidth: 720, minHeight: 540)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open CAD File…") {
                    NotificationCenter.default.post(name: .showCADImporter, object: nil)
                }
                .keyboardShortcut("o")
                OpenRecentMenu()
                Divider()
                Button("Reveal in Finder") {
                    guard let url = CADWindowRouter.shared.keyStore?.representedURL else { return }
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
            CommandGroup(before: .toolbar) {
                Section("Standard Views") {
                    viewButton("Front", .standardView(.front), "1")
                    viewButton("Back", .standardView(.back), "2")
                    viewButton("Left", .standardView(.left), "3")
                    viewButton("Right", .standardView(.right), "4")
                    viewButton("Top", .standardView(.top), "5")
                    viewButton("Bottom", .standardView(.bottom), "6")
                    viewButton("Isometric", .standardView(.isometric), "7")
                }
                Divider()
                viewButton("Fit to Window", .fit, "0")
                Button("Toggle Perspective") { post(.toggleProjection) }
                    .keyboardShortcut("p", modifiers: [])
                Button("Toggle Edges") { post(.toggleEdges) }
                    .keyboardShortcut("e", modifiers: [])
                Divider()
            }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    updater.checkForUpdates()
                }
                .disabled(!updater.canCheckForUpdates)
            }
        }

        Settings {
            SettingsView(updater: updater)
        }
    }

    private func viewButton(_ title: String, _ command: CADViewCommand, _ key: Character) -> some View {
        Button(title) { post(command) }
            .keyboardShortcut(KeyEquivalent(key), modifiers: .command)
    }

    private func post(_ command: CADViewCommand) {
        NotificationCenter.default.post(name: .cadViewCommand, object: command)
    }
}

/// File > Open Recent, backed by the system recent-documents list.
private struct OpenRecentMenu: View {
    @State private var urls: [URL] = NSDocumentController.shared.recentDocumentURLs

    var body: some View {
        Menu("Open Recent") {
            ForEach(urls, id: \.self) { url in
                Button(url.lastPathComponent) { CADWindowRouter.shared.open(url) }
            }
            if !urls.isEmpty {
                Divider()
                Button("Clear Menu") {
                    NSDocumentController.shared.clearRecentDocuments(nil)
                    urls = []
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            urls = NSDocumentController.shared.recentDocumentURLs
        }
    }
}

extension Notification.Name {
    static let showCADImporter = Notification.Name("showCADImporter")
}
