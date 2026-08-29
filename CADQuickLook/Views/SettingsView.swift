import SwiftUI

struct SettingsView: View {
    @Bindable var updater: UpdaterController
    @State private var navigationPresetRawValue = CADPreferences.navigationPreset.rawValue
    @State private var cameraProjectionRawValue = CADPreferences.cameraProjection.rawValue
    @State private var lengthUnitRawValue = CADPreferences.lengthUnit.rawValue

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
        .frame(width: 480, height: 520)
        .navigationTitle("General")
        .onChange(of: navigationPresetRawValue) { _, rawValue in
            guard let preset = CADNavigationPreset(rawValue: rawValue) else { return }
            CADPreferences.setNavigationPreset(preset)
        }
        .onChange(of: cameraProjectionRawValue) { _, rawValue in
            guard let projection = CADCameraProjection(rawValue: rawValue) else { return }
            CADPreferences.setCameraProjection(projection)
        }
        .onChange(of: lengthUnitRawValue) { _, rawValue in
            guard let unit = CADLengthUnit(rawValue: rawValue) else { return }
            CADPreferences.setLengthUnit(unit)
        }
        .onAppear {
            updater.refresh()
            navigationPresetRawValue = CADPreferences.navigationPreset.rawValue
            cameraProjectionRawValue = CADPreferences.cameraProjection.rawValue
            lengthUnitRawValue = CADPreferences.lengthUnit.rawValue
        }
    }
}
