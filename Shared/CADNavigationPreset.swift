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
    case shadedWithEdges, shadedWithoutEdges, unshaded, translucent, wireframe
    var id: Self { self }

    var title: String {
        switch self {
        case .shadedWithEdges: "Shaded with edges"
        case .shadedWithoutEdges: "Shaded without edges"
        case .unshaded: "Unshaded"
        case .translucent: "Translucent"
        case .wireframe: "Wireframe"
        }
    }

    var showsEdges: Bool { self != .shadedWithoutEdges }
    var showsSurface: Bool { self != .wireframe }
}

/// What orbiting rotates about.
enum CADOrbitPivotMode: String, CaseIterable, Identifiable, CADDisplayMode {
    case origin, modelCenter, cursor
    var id: Self { self }

    var title: String {
        switch self {
        case .origin: "Orbit about origin"
        case .modelCenter: "Orbit about model centre"
        case .cursor: "Orbit about cursor"
        }
    }
}

/// Decimal places for measurements; auto = a sensible count per unit.
enum CADMeasurementPrecision: String, CaseIterable, Identifiable, CADDisplayMode {
    case auto, one, two, three, four
    var id: Self { self }

    var title: String {
        switch self {
        case .auto: "Automatic"
        case .one: "1 decimal"
        case .two: "2 decimals"
        case .three: "3 decimals"
        case .four: "4 decimals"
        }
    }

    var fractionDigits: Int? {
        switch self {
        case .auto: nil
        case .one: 1
        case .two: 2
        case .three: 3
        case .four: 4
        }
    }
}

/// Commands from the View menu / keyboard, delivered to the viewer.
enum CADViewCommand {
    case standardView(CADStandardView)
    case fit
    case toggleProjection
    case toggleEdges
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
    static let cadMeasurementOptionsDidChange = Notification.Name("cadMeasurementOptionsDidChange")
    /// object: a CADViewCommand. Handled by the key window's viewer.
    static let cadViewCommand = Notification.Name("cadViewCommand")
}

/// What hovering a circular edge or a cylindrical/spherical face reports.
enum CADCircularMeasure: String, CaseIterable, Identifiable, CADDisplayMode {
    case diameter, radius
    var id: Self { self }

    var title: String {
        switch self {
        case .diameter: "Diameter"
        case .radius: "Radius"
        }
    }
}

/// What clicking two entities reports. Angle falls back to distance when
/// either entity has no direction (a vertex, a free-form face).
enum CADPairMeasure: String, CaseIterable, Identifiable, CADDisplayMode {
    case distance, angle
    var id: Self { self }

    var title: String {
        switch self {
        case .distance: "Distance"
        case .angle: "Angle"
        }
    }
}

enum CADPreferences {
    static let suiteName = "com.liamflanagan.CADQuickLook"
    static let navigationPresetKey = "navigationPreset"
    static let cameraProjectionKey = "cameraProjection"
    static let lengthUnitKey = "lengthUnit"
    static let shadingModeKey = "shadingMode"
    static let hiddenEdgeModeKey = "hiddenEdgeMode"
    static let tangentEdgeModeKey = "tangentEdgeMode"
    static let circularMeasureKey = "circularMeasure"
    static let pairMeasureKey = "pairMeasure"
    static let orbitPivotKey = "orbitPivot"
    static let measurementPrecisionKey = "measurementPrecision"
    static let showsMeasurementDetailsKey = "showsMeasurementDetails"
    static let opensFilesInNewWindowKey = "opensFilesInNewWindow"

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

    static var circularMeasure: CADCircularMeasure {
        rawValue(forKey: circularMeasureKey).flatMap(CADCircularMeasure.init(rawValue:)) ?? .diameter
    }

    static func setCircularMeasure(_ measure: CADCircularMeasure) {
        defaults.set(measure.rawValue, forKey: circularMeasureKey)
        NotificationCenter.default.post(name: .cadMeasurementOptionsDidChange, object: nil)
    }

    static var orbitPivot: CADOrbitPivotMode {
        rawValue(forKey: orbitPivotKey).flatMap(CADOrbitPivotMode.init(rawValue:)) ?? .modelCenter
    }

    static func setOrbitPivot(_ mode: CADOrbitPivotMode) {
        defaults.set(mode.rawValue, forKey: orbitPivotKey)
    }

    static var measurementPrecision: CADMeasurementPrecision {
        rawValue(forKey: measurementPrecisionKey).flatMap(CADMeasurementPrecision.init(rawValue:)) ?? .auto
    }

    static func setMeasurementPrecision(_ precision: CADMeasurementPrecision) {
        defaults.set(precision.rawValue, forKey: measurementPrecisionKey)
        NotificationCenter.default.post(name: .cadMeasurementOptionsDidChange, object: nil)
    }

    /// Second readout row: arc length for circles, height for cylinders.
    static var showsMeasurementDetails: Bool {
        defaults.object(forKey: showsMeasurementDetailsKey) as? Bool ?? false
    }

    static func setShowsMeasurementDetails(_ shows: Bool) {
        defaults.set(shows, forKey: showsMeasurementDetailsKey)
        NotificationCenter.default.post(name: .cadMeasurementOptionsDidChange, object: nil)
    }

    /// App only: opening a file while one is shown opens a second window.
    static var opensFilesInNewWindow: Bool {
        defaults.object(forKey: opensFilesInNewWindowKey) as? Bool ?? true
    }

    static func setOpensFilesInNewWindow(_ opens: Bool) {
        defaults.set(opens, forKey: opensFilesInNewWindowKey)
    }

    static var pairMeasure: CADPairMeasure {
        rawValue(forKey: pairMeasureKey).flatMap(CADPairMeasure.init(rawValue:)) ?? .distance
    }

    static func setPairMeasure(_ measure: CADPairMeasure) {
        defaults.set(measure.rawValue, forKey: pairMeasureKey)
        NotificationCenter.default.post(name: .cadMeasurementOptionsDidChange, object: nil)
    }

    /// Group value first; falls back to the pre-App-Group per-process value.
    private static func rawValue(forKey key: String) -> String? {
        defaults.string(forKey: key) ?? UserDefaults.standard.string(forKey: key)
    }
}
