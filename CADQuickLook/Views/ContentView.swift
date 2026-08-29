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
                LoadingStateView(url: store.loadingURL, progress: store.loadingProgress)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                EmptyStateView { showsImporter = true }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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

private struct EmptyStateView: View {
    let onOpen: () -> Void

    private let formats: [(name: String, extensions: String)] = [
        ("STEP", ".step  .stp"),
        ("IGES", ".iges  .igs"),
        ("BREP", ".brep"),
        ("STL", ".stl"),
        ("DXF", ".dxf")
    ]

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 96, height: 96)
                .padding(.bottom, 6)
            Text("CADQuickLook")
                .font(.system(size: 22, weight: .semibold))
                .padding(.bottom, 22)

            Text("SUPPORTED FORMATS")
                .font(.system(size: 11, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 10)
            VStack(spacing: 0) {
                ForEach(Array(formats.enumerated()), id: \.offset) { index, format in
                    HStack {
                        Text(format.name)
                            .font(.system(size: 13, weight: .medium))
                        Spacer(minLength: 24)
                        Text(format.extensions)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                    if index < formats.count - 1 {
                        Divider().opacity(0.5)
                    }
                }
            }
            .frame(width: 220)

            Button("Open File…", action: onOpen)
                .keyboardShortcut("o")
                .controlSize(.large)
                .padding(.top, 26)
        }
    }
}

private struct LoadingStateView: View {
    let url: URL?
    let progress: CADLoadProgress?

    private var fileSize: String? {
        guard let url,
              let bytes = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    var body: some View {
        VStack(spacing: 10) {
            Text(url?.lastPathComponent ?? "Loading")
                .font(.system(size: 16, weight: .semibold))
                .lineLimit(1)
            if let fileSize {
                Text(fileSize)
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
            Group {
                if let fraction = progress?.fraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView(value: nil as Double?)
                }
            }
            .progressViewStyle(.linear)
            .frame(width: 260)
            .padding(.top, 12)
            Text(progress?.title ?? "Opening")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .contentTransition(.numericText())
        }
    }
}
