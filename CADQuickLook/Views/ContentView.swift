import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var store: CADDocumentStore
    @State private var showsImporter = false

    var body: some View {
        Group {
            if let asset = store.asset {
                CADViewerSurfaceView(asset: asset)
            } else if store.isLoading {
                ProgressView("Tessellating CAD model…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView {
                    Label("Open a CAD Model", systemImage: "view.3d")
                } description: {
                    Text("STEP, IGES, BREP, and STL files open in the same viewer used by Finder Quick Look.")
                } actions: {
                    Button("Open File…") { showsImporter = true }
                }
            }
        }
        .fileImporter(
            isPresented: $showsImporter,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { store.open(url) }
            case .failure(let error): store.errorMessage = error.localizedDescription
            }
        }
        .alert("CADQuickLook", isPresented: Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "Unknown error")
        }
        .onReceive(NotificationCenter.default.publisher(for: .showCADImporter)) { _ in
            showsImporter = true
        }
        .ignoresSafeArea(.container, edges: .top)
        .overlay(alignment: .top) {
            HStack(spacing: 0) {
                Color.clear.frame(width: 82).allowsHitTesting(false)
                Color.clear
                    .contentShape(Rectangle())
                    .allowsWindowActivationEvents(true)
                    .gesture(WindowDragGesture())
                Color.clear.frame(width: 180).allowsHitTesting(false)
            }
            .frame(height: 30)
        }
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    }
}
