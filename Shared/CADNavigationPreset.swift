import Foundation

enum CADNavigationPreset: String, CaseIterable, Identifiable {
    case solidWorks
    case nx
    case catia
    case creo
    case onshape

    var id: Self { self }

    var title: String {
        switch self {
        case .solidWorks: "SolidWorks"
        case .nx: "NX"
        case .catia: "CATIA"
        case .creo: "Creo"
        case .onshape: "Onshape"
        }
    }

    var controlSummary: String {
        switch self {
        case .solidWorks:
            "Middle-drag rotates · Control-middle-drag pans · Shift-middle-drag zooms"
        case .nx:
            "Middle-drag rotates · Shift-middle-drag pans · Control-middle-drag zooms"
        case .catia:
            "Middle-drag pans · Middle + left-drag rotates · Control-middle-drag zooms"
        case .creo:
            "Middle-drag spins · Shift-middle-drag pans · Control-middle-drag zooms or turns"
        case .onshape:
            "Right-drag rotates · Control-right-drag or middle-drag pans · Scroll zooms"
        }
    }
}

enum CADCameraProjection: String, CaseIterable, Identifiable {
    case perspective
    case orthographic

    var id: Self { self }
    var title: String { rawValue.capitalized }
}

extension Notification.Name {
    static let cadCameraProjectionDidChange = Notification.Name("cadCameraProjectionDidChange")
}

enum CADPreferences {
    static let suiteName = "com.liamflanagan.CADQuickLook"
    static let previewSuiteName = "com.liamflanagan.CADQuickLook.Preview"
    static let navigationPresetKey = "navigationPreset"
    private static let navigationPresetModifiedAtKey = "navigationPresetModifiedAt"
    static let cameraProjectionKey = "cameraProjection"
    private static let cameraProjectionModifiedAtKey = "cameraProjectionModifiedAt"

    static var navigationPreset: CADNavigationPreset {
        let rawValue = resolvedRawValue(
            valueKey: navigationPresetKey,
            modifiedAtKey: navigationPresetModifiedAtKey
        )
        return rawValue.flatMap(CADNavigationPreset.init(rawValue:)) ?? .onshape
    }

    static func setNavigationPreset(_ preset: CADNavigationPreset) {
        setRawValue(
            preset.rawValue,
            valueKey: navigationPresetKey,
            modifiedAtKey: navigationPresetModifiedAtKey
        )
    }

    static var cameraProjection: CADCameraProjection {
        let rawValue = resolvedRawValue(
            valueKey: cameraProjectionKey,
            modifiedAtKey: cameraProjectionModifiedAtKey
        )
        return rawValue.flatMap(CADCameraProjection.init(rawValue:)) ?? .perspective
    }

    static func setCameraProjection(_ projection: CADCameraProjection) {
        setRawValue(
            projection.rawValue,
            valueKey: cameraProjectionKey,
            modifiedAtKey: cameraProjectionModifiedAtKey
        )
        NotificationCenter.default.post(name: .cadCameraProjectionDidChange, object: projection)
    }

    private static func resolvedRawValue(valueKey: String, modifiedAtKey: String) -> String? {
        var preferences = [
            currentProcessPreference(valueKey: valueKey, modifiedAtKey: modifiedAtKey),
            storedPreference(in: suiteName, valueKey: valueKey, modifiedAtKey: modifiedAtKey)
        ]
        if Bundle.main.bundleIdentifier == suiteName {
            preferences.append(previewContainerPreference(valueKey: valueKey, modifiedAtKey: modifiedAtKey))
        }
        return preferences
            .compactMap { $0 }
            .max { $0.modifiedAt < $1.modifiedAt }?
            .rawValue
    }

    private static func setRawValue(_ rawValue: String, valueKey: String, modifiedAtKey: String) {
        let modifiedAt = Date().timeIntervalSince1970
        UserDefaults.standard.set(rawValue, forKey: valueKey)
        UserDefaults.standard.set(modifiedAt, forKey: modifiedAtKey)
        UserDefaults.standard.synchronize()
        write(
            rawValue: rawValue,
            modifiedAt: modifiedAt,
            valueKey: valueKey,
            modifiedAtKey: modifiedAtKey,
            to: suiteName
        )

        // The containing app is unsandboxed and can keep the Quick Look
        // extension's writable mirror aligned with its Settings window.
        if Bundle.main.bundleIdentifier == suiteName {
            writePreviewContainerPreference(
                rawValue: rawValue,
                modifiedAt: modifiedAt,
                valueKey: valueKey,
                modifiedAtKey: modifiedAtKey
            )
        }
    }

    private static func currentProcessPreference(
        valueKey: String,
        modifiedAtKey: String
    ) -> (rawValue: String, modifiedAt: Double)? {
        guard let rawValue = UserDefaults.standard.string(forKey: valueKey) else { return nil }
        return (rawValue, UserDefaults.standard.double(forKey: modifiedAtKey))
    }

    private static func storedPreference(
        in suite: String,
        valueKey: String,
        modifiedAtKey: String
    ) -> (rawValue: String, modifiedAt: Double)? {
        guard let defaults = UserDefaults(suiteName: suite),
              let rawValue = defaults.string(forKey: valueKey) else { return nil }
        let modifiedAt = defaults.double(forKey: modifiedAtKey)
        return (rawValue, modifiedAt)
    }

    private static func previewContainerPreference(
        valueKey: String,
        modifiedAtKey: String
    ) -> (rawValue: String, modifiedAt: Double)? {
        guard let dictionary = previewContainerDictionary(),
              let rawValue = dictionary[valueKey] as? String else { return nil }
        let modifiedAt = (dictionary[modifiedAtKey] as? NSNumber)?.doubleValue ?? 0
        return (rawValue, modifiedAt)
    }

    private static func writePreviewContainerPreference(
        rawValue: String,
        modifiedAt: Double,
        valueKey: String,
        modifiedAtKey: String
    ) {
        var dictionary = previewContainerDictionary() ?? [:]
        dictionary[valueKey] = rawValue
        dictionary[modifiedAtKey] = modifiedAt
        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: dictionary,
            format: .binary,
            options: 0
        ) else { return }
        try? data.write(to: previewPreferencesURL, options: .atomic)
    }

    private static func previewContainerDictionary() -> [String: Any]? {
        guard let data = try? Data(contentsOf: previewPreferencesURL),
              let propertyList = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
              ) else { return nil }
        return propertyList as? [String: Any]
    }

    private static var previewPreferencesURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers", isDirectory: true)
            .appendingPathComponent(previewSuiteName, isDirectory: true)
            .appendingPathComponent("Data/Library/Preferences", isDirectory: true)
            .appendingPathComponent("\(previewSuiteName).plist")
    }

    private static func write(
        rawValue: String,
        modifiedAt: Double,
        valueKey: String,
        modifiedAtKey: String,
        to suite: String
    ) {
        CFPreferencesSetAppValue(
            valueKey as CFString,
            rawValue as CFString,
            suite as CFString
        )
        CFPreferencesSetAppValue(
            modifiedAtKey as CFString,
            modifiedAt as CFNumber,
            suite as CFString
        )
        CFPreferencesAppSynchronize(suite as CFString)
    }
}
