import AppKit
import SwiftUI

@MainActor
final class CADApplicationDelegate: NSObject, NSApplicationDelegate {
    private var pendingURLs: [URL] = []
    var openURL: ((URL) -> Void)? {
        didSet { drainPendingURLs() }
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        receive(filenames.map(URL.init(fileURLWithPath:)))
        sender.reply(toOpenOrPrint: .success)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        receive(urls)
    }

    private func receive(_ urls: [URL]) {
        guard let openURL else {
            pendingURLs.append(contentsOf: urls)
            return
        }
        urls.forEach(openURL)
    }

    private func drainPendingURLs() {
        guard let openURL, !pendingURLs.isEmpty else { return }
        let urls = pendingURLs
        pendingURLs.removeAll()
        urls.forEach(openURL)
    }
}

@main
struct CADQuickLookApp: App {
    @NSApplicationDelegateAdaptor(CADApplicationDelegate.self) private var appDelegate
    @State private var store = CADDocumentStore()
    @State private var updater = UpdaterController()

    var body: some Scene {
        WindowGroup {
            ContentView(store: store)
                .frame(minWidth: 720, minHeight: 540)
                .onOpenURL(perform: store.open)
                .onAppear {
                    appDelegate.openURL = store.open
                }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open CAD File…") {
                    NotificationCenter.default.post(name: .showCADImporter, object: nil)
                }
                .keyboardShortcut("o")
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
}

extension Notification.Name {
    static let showCADImporter = Notification.Name("showCADImporter")
}
