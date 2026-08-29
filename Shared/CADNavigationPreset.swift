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

enum CADLengthUnit: String, CaseIterable, Identifiable {
    case millimeters
    case centimeters
    case meters
    case inches

    var id: Self { self }

    var title: String {
        switch self {
        case .millimeters: "Millimeters"
        case .centimeters: "Centimeters"
        case .meters: "Meters"
        case .inches: "Inches"
        }
    }

    var symbol: String {
        switch self {
        case .millimeters: "mm"
        case .centimeters: "cm"
        case .meters: "m"
        case .inches: "in"
        }
    }

    /// Multiplier from model millimetres (Open CASCADE's import unit) to this unit.
    var scale: Double {
        switch self {
        case .millimeters: 1
        case .centimeters: 0.1
        case .meters: 0.001
        case .inches: 1 / 25.4
        }
    }

    var fractionDigits: Int {
        switch self {
        case .millimeters: 3
        case .centimeters: 4
        case .meters: 6
        case .inches: 4
        }
    }
}

/// One choice in a display-option submenu (shading, hidden edges, tangent edges).
protocol CADDisplayMode: RawRepresentable<String>, CaseIterable, Hashable {
    var title: String { get }
}

enum CADShadingMode: String, CaseIterable, Identifiable, CADDisplayMode {
    case shadedWithEdges, shadedWithoutEdges, unshaded, translucent
    var id: Self { self }

    var title: String {
        switch self {
        case .shadedWithEdges: "Shaded with edges"
        case .shadedWithoutEdges: "Shaded without edges"
        case .unshaded: "Unshaded"
        case .translucent: "Translucent"
        }
    }

    var showsEdges: Bool { self != .shadedWithoutEdges }
}

enum CADHiddenEdgeMode: String, CaseIterable, Identifiable, CADDisplayMode {
    case visible, removed
    var id: Self { self }

    var title: String {
        switch self {
        case .visible: "Hidden edges visible"
        case .removed: "Hidden edges removed"
        }
    }
}

enum CADTangentEdgeMode: String, CaseIterable, Identifiable, CADDisplayMode {
    case visible, phantom, removed
    var id: Self { self }

    var title: String {
        switch self {
        case .visible: "Tangent edges visible"
        case .phantom: "Tangent edges phantom"
        case .removed: "Tangent edges removed"
        }
    }
}

/// How the model is drawn; see `CADSceneFactory.apply(_:to:)`.
struct CADDisplayOptions: Equatable {
    var shading: CADShadingMode = .shadedWithEdges
    var hiddenEdges: CADHiddenEdgeMode = .removed
    var tangentEdges: CADTangentEdgeMode = .visible

    static let `default` = CADDisplayOptions()
}

extension Notification.Name {
    static let cadCameraProjectionDidChange = Notification.Name("cadCameraProjectionDidChange")
    static let cadLengthUnitDidChange = Notification.Name("cadLengthUnitDidChange")
    static let cadDisplayOptionsDidChange = Notification.Name("cadDisplayOptionsDidChange")
}

enum CADPreferences {
    static let suiteName = "com.liamflanagan.CADQuickLook"
    static let navigationPresetKey = "navigationPreset"
    static let cameraProjectionKey = "cameraProjection"
    static let lengthUnitKey = "lengthUnit"
    static let shadingModeKey = "shadingMode"
    static let hiddenEdgeModeKey = "hiddenEdgeMode"
    static let tangentEdgeModeKey = "tangentEdgeMode"

    /// App Group shared by the app and both Quick Look extensions. The
    /// identifier is expanded into Info.plist from the signing team at build
    /// time (see CAD_APP_GROUP in project.yml).
    static let appGroupIdentifier: String? = {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "CADAppGroup") as? String,
              !value.isEmpty, !value.hasPrefix("."), !value.contains("$(") else { return nil }
        return value
    }()

    nonisolated(unsafe) private static let defaults: UserDefaults = {
        if let appGroupIdentifier, let shared = UserDefaults(suiteName: appGroupIdentifier) {
            return shared
        }
        return .standard
    }()

    static var navigationPreset: CADNavigationPreset {
        rawValue(forKey: navigationPresetKey).flatMap(CADNavigationPreset.init(rawValue:)) ?? .onshape
    }

    static func setNavigationPreset(_ preset: CADNavigationPreset) {
        defaults.set(preset.rawValue, forKey: navigationPresetKey)
    }

    static var cameraProjection: CADCameraProjection {
        rawValue(forKey: cameraProjectionKey).flatMap(CADCameraProjection.init(rawValue:)) ?? .orthographic
    }

    static func setCameraProjection(_ projection: CADCameraProjection) {
        defaults.set(projection.rawValue, forKey: cameraProjectionKey)
        NotificationCenter.default.post(name: .cadCameraProjectionDidChange, object: projection)
    }

    static var lengthUnit: CADLengthUnit {
        rawValue(forKey: lengthUnitKey).flatMap(CADLengthUnit.init(rawValue:)) ?? .millimeters
    }

    static func setLengthUnit(_ unit: CADLengthUnit) {
        defaults.set(unit.rawValue, forKey: lengthUnitKey)
        NotificationCenter.default.post(name: .cadLengthUnitDidChange, object: unit)
    }

    static var displayOptions: CADDisplayOptions {
        CADDisplayOptions(
            shading: rawValue(forKey: shadingModeKey).flatMap(CADShadingMode.init(rawValue:)) ?? .shadedWithEdges,
            hiddenEdges: rawValue(forKey: hiddenEdgeModeKey).flatMap(CADHiddenEdgeMode.init(rawValue:)) ?? .removed,
            tangentEdges: rawValue(forKey: tangentEdgeModeKey).flatMap(CADTangentEdgeMode.init(rawValue:)) ?? .visible
        )
    }

    static func setDisplayOptions(_ options: CADDisplayOptions) {
        defaults.set(options.shading.rawValue, forKey: shadingModeKey)
        defaults.set(options.hiddenEdges.rawValue, forKey: hiddenEdgeModeKey)
        defaults.set(options.tangentEdges.rawValue, forKey: tangentEdgeModeKey)
        NotificationCenter.default.post(name: .cadDisplayOptionsDidChange, object: nil)
    }

    /// Group value first; falls back to the pre-App-Group per-process value.
    private static func rawValue(forKey key: String) -> String? {
        defaults.string(forKey: key) ?? UserDefaults.standard.string(forKey: key)
    }
}
