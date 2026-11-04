import SwiftUI

struct SettingsView: View {
    @Bindable var updater: UpdaterController
    @State private var navigationPresetRawValue = CADPreferences.navigationPreset.rawValue
    @State private var cameraProjectionRawValue = CADPreferences.cameraProjection.rawValue
    @State private var lengthUnitRawValue = CADPreferences.lengthUnit.rawValue
    @State private var opensInNewWindow = CADPreferences.opensFilesInNewWindow
    @State private var modelCacheEnabled = CADPreferences.modelCacheEnabled
    @State private var modelCacheLimit = CADPreferences.modelCacheLimitGigabytes
    /// Allocated bytes, or nil while being measured.
    @State private var modelCacheSize: Int64?

    private var navigationPreset: CADNavigationPreset {
        CADNavigationPreset(rawValue: navigationPresetRawValue) ?? .onshape
    }

    var body: some View {
        Form {
            Section("Navigation") {
                Picker("View controls", selection: $navigationPresetRawValue) {
                    ForEach(CADNavigationPreset.allCases) { preset in
                        Text(preset.title).tag(preset.rawValue)
                    }
                }
                .pickerStyle(.menu)

                Text(navigationPreset.controlSummary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Windows") {
                Toggle("Open files in a new window", isOn: $opensInNewWindow)
                Text("Off: opening a file replaces the one in the front window.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Camera") {
                Picker("Projection", selection: $cameraProjectionRawValue) {
                    ForEach(CADCameraProjection.allCases) { projection in
                        Text(projection.title).tag(projection.rawValue)
                    }
                }
                .pickerStyle(.menu)
            }

            Section("Measurements") {
                Picker("Units", selection: $lengthUnitRawValue) {
                    ForEach(CADLengthUnit.allCases) { unit in
                        Text("\(unit.title) (\(unit.symbol))").tag(unit.rawValue)
                    }
                }
                .pickerStyle(.menu)
                Text("STEP and IGES files are converted from their declared unit. STL and BREP files carry no unit and are assumed to be in millimeters.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Model cache") {
                Toggle("Cache processed models", isOn: $modelCacheEnabled)
                Picker("Maximum size", selection: $modelCacheLimit) {
                    ForEach(CADPreferences.modelCacheLimitChoices, id: \.self) { gigabytes in
                        Text("\(gigabytes) GB").tag(gigabytes)
                    }
                }
                .pickerStyle(.menu)
                .disabled(!modelCacheEnabled)
                LabeledContent(modelCacheSizeText) {
                    Button("Clear Cache") {
                        updateModelCache { $0.removeAll() }
                    }
                    .disabled(modelCacheSize == 0)
                }
                Text("Large models open instantly the second time. The cache is limited to the chosen size and never stores file names.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Updates") {
                Toggle("Check for updates automatically", isOn: $updater.automaticallyChecksForUpdates)

                LabeledContent("Last checked") {
                    if let date = updater.lastUpdateCheckDate {
                        Text(date, format: .dateTime.day().month().year().hour().minute())
                    } else {
                        Text("Never")
                    }
                }
                .foregroundStyle(.secondary)

                Button("Check Now…") {
                    updater.checkForUpdates()
                }
                .disabled(!updater.canCheckForUpdates)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 600)
        .navigationTitle("General")
        .onChange(of: navigationPresetRawValue) { _, rawValue in
            guard let preset = CADNavigationPreset(rawValue: rawValue) else { return }
            CADPreferences.setNavigationPreset(preset)
        }
        .onChange(of: cameraProjectionRawValue) { _, rawValue in
            guard let projection = CADCameraProjection(rawValue: rawValue) else { return }
            CADPreferences.setCameraProjection(projection)
        }
        .onChange(of: opensInNewWindow) { _, opens in
            CADPreferences.setOpensFilesInNewWindow(opens)
        }
        .onChange(of: lengthUnitRawValue) { _, rawValue in
            guard let unit = CADLengthUnit(rawValue: rawValue) else { return }
            CADPreferences.setLengthUnit(unit)
        }
        .onChange(of: modelCacheEnabled) { _, enabled in
            CADPreferences.setModelCacheEnabled(enabled)
            if !enabled { updateModelCache { $0.removeAll() } }
        }
        .onChange(of: modelCacheLimit) { _, gigabytes in
            CADPreferences.setModelCacheLimitGigabytes(gigabytes)
            updateModelCache { $0.evict() }
        }
        .onAppear {
            updater.refresh()
            modelCacheEnabled = CADPreferences.modelCacheEnabled
            modelCacheLimit = CADPreferences.modelCacheLimitGigabytes
            updateModelCache { _ in }
            navigationPresetRawValue = CADPreferences.navigationPreset.rawValue
            cameraProjectionRawValue = CADPreferences.cameraProjection.rawValue
            lengthUnitRawValue = CADPreferences.lengthUnit.rawValue
        }
    }

    private var modelCacheSizeText: String {
        switch modelCacheSize {
        case nil: "Measuring…"
        case 0: "Empty"
        case let bytes?: "Using \(bytes.formatted(.byteCount(style: .file)))"
        }
    }

    /// Runs `change` on the cache off the main thread, then re-measures it.
    private func updateModelCache(_ change: @escaping @Sendable (CADModelCache) -> Void) {
        Task {
            modelCacheSize = await Task.detached(priority: .utility) {
                guard let cache = CADModelCache.shared else { return Int64(0) }
                change(cache)
                return cache.size()
            }.value
        }
    }
}
