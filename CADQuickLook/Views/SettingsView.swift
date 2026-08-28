import SwiftUI

struct SettingsView: View {
    @State private var navigationPresetRawValue = CADPreferences.navigationPreset.rawValue
    @State private var cameraProjectionRawValue = CADPreferences.cameraProjection.rawValue

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

            Section("Camera") {
                Picker("Projection", selection: $cameraProjectionRawValue) {
                    ForEach(CADCameraProjection.allCases) { projection in
                        Text(projection.title).tag(projection.rawValue)
                    }
                }
                .pickerStyle(.menu)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 265)
        .navigationTitle("General")
        .onChange(of: navigationPresetRawValue) { _, rawValue in
            guard let preset = CADNavigationPreset(rawValue: rawValue) else { return }
            CADPreferences.setNavigationPreset(preset)
        }
        .onChange(of: cameraProjectionRawValue) { _, rawValue in
            guard let projection = CADCameraProjection(rawValue: rawValue) else { return }
            CADPreferences.setCameraProjection(projection)
        }
        .onAppear {
            navigationPresetRawValue = CADPreferences.navigationPreset.rawValue
            cameraProjectionRawValue = CADPreferences.cameraProjection.rawValue
        }
    }
}
