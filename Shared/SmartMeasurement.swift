import Foundation
import SceneKit
import simd

enum SmartSelectionTarget: Equatable {
    /// `index` is into `CADModelAsset.topologicalVertices`.
    case vertex(index: Int, position: SCNVector3)
    case edge(index: Int, position: SCNVector3)
    case face(index: Int, position: SCNVector3)

    static func == (lhs: SmartSelectionTarget, rhs: SmartSelectionTarget) -> Bool {
        switch (lhs, rhs) {
        case (.vertex(let a, _), .vertex(let b, _)): a == b
        case (.edge(let a, _), .edge(let b, _)): a == b
        case (.face(let a, _), .face(let b, _)): a == b
        default: false
        }
    }
}

/// A measured quantity in model millimetres; formatted in the user's unit at display time.
enum SmartMeasurementValue {
    case length(Double)
    case area(Double)
    case point(SCNVector3)
    /// Degrees.
    case angle(Double)

    var formatted: String {
        switch self {
        case .length(let value): CADValueFormatter.length(value)
        case .area(let value): CADValueFormatter.area(value)
        case .point(let point): CADValueFormatter.point(point)
        case .angle(let degrees): CADValueFormatter.angle(degrees)
        }
    }
}

/// One measurement: a label ("Diameter") and its value, plus the points of a
/// distance to draw on the model.
struct SmartMeasurementResult {
    let label: String
    let value: SmartMeasurementValue
    let points: [SCNVector3]
    /// Optional second row (arc length, cylinder height), shown only when
    /// the "Show details" measure setting is on.
    var detailLabel: String? = nil
    var detailValue: SmartMeasurementValue? = nil

    var clipboardText: String { value.formatted }
}

/// Onshape-style measurement: hovering shows one value for the entity under
/// the cursor; clicking one entity then another shows the distance (or
/// angle) between them.
@MainActor
final class SmartMeasurementSession {
    var onResult: ((SmartMeasurementResult?) -> Void)?
    /// The first-clicked entity while waiting for a second one (nil when none),
    /// so the view can keep it marked on screen.
    var onPendingChanged: ((SmartSelectionTarget?) -> Void)?

    private let asset: CADModelAsset
    private var selectedResult: SmartMeasurementResult?
    /// Entities behind `selectedResult`, so a settings change can recompute it.
    private var selectedTargets: [SmartSelectionTarget] = []
    /// First entity of a two-entity measurement.
    private var pending: SmartSelectionTarget?

    init(asset: CADModelAsset) {
        self.asset = asset
    }

    func hover(_ target: SmartSelectionTarget?) {
        // A clicked measurement stays on screen while the cursor wanders
        // (so it can be read or copied); hover values show when nothing is
        // selected. Escape or a click on empty space clears the selection.
        if let selectedResult {
            onResult?(selectedResult)
            return
        }
        guard let target else {
            onResult?(nil)
            return
        }
        onResult?(measurement(for: target))
    }

    func select(_ target: SmartSelectionTarget) {
        if let first = pending, first != target, let pair = pairMeasurement(first, target) {
            selectedResult = pair
            selectedTargets = [first, target]
            pending = nil
        } else {
            selectedResult = measurement(for: target)
            selectedTargets = [target]
            pending = target
        }
        onPendingChanged?(pending)
        onResult?(selectedResult)
    }

    /// Click on empty space or Escape: drop the selection.
    func deselect() {
        pending = nil
        selectedResult = nil
        selectedTargets = []
        onPendingChanged?(nil)
        onResult?(nil)
    }

    /// Recomputes the current selection after a settings change (units,
    /// diameter vs radius, distance vs angle).
    func refresh() {
        switch selectedTargets.count {
        case 1: selectedResult = measurement(for: selectedTargets[0])
        case 2: selectedResult = pairMeasurement(selectedTargets[0], selectedTargets[1]) ?? selectedResult
        default: break
        }
        onResult?(selectedResult)
    }

    // MARK: - Single entity

    private func measurement(for target: SmartSelectionTarget) -> SmartMeasurementResult {
        switch target {
        case .vertex(_, let position):
            return SmartMeasurementResult(label: "Position", value: .point(position), points: [])
        case .edge(let index, _):
            let edge = asset.edges[index]
            if edge.curveType == CADCurveTypeCircle.rawValue {
                var result = circular(diameter: edge.exactDiameter)
                if CADPreferences.showsMeasurementDetails {
                    result.detailLabel = "Length"
                    result.detailValue = .length(asset.edgeLength(index))
                }
                return result
            }
            return SmartMeasurementResult(label: "Length", value: .length(asset.edgeLength(index)), points: [])
        case .face(let index, _):
            let face = asset.faceRanges[index]
            switch UInt32(face.surfaceType) {
            case CADSurfaceTypeCylinder.rawValue:
                var result = circular(diameter: face.radius * 2)
                if CADPreferences.showsMeasurementDetails, face.extent > 0 {
                    result.detailLabel = "Height"
                    result.detailValue = .length(face.extent)
                }
                return result
            case CADSurfaceTypeSphere.rawValue:
                return circular(diameter: face.radius * 2)
            default:
                return SmartMeasurementResult(label: "Area", value: .area(asset.faceArea(index)), points: [])
            }
        }
    }

    private func circular(diameter: Double) -> SmartMeasurementResult {
        switch CADPreferences.circularMeasure {
        case .diameter: SmartMeasurementResult(label: "Diameter", value: .length(diameter), points: [])
        case .radius: SmartMeasurementResult(label: "Radius", value: .length(diameter / 2), points: [])
        }
    }

    // MARK: - Two entities

    private func pairMeasurement(_ first: SmartSelectionTarget, _ second: SmartSelectionTarget) -> SmartMeasurementResult? {
        if CADPreferences.pairMeasure == .angle,
           let a = direction(of: first), let b = direction(of: second) {
            return SmartMeasurementResult(label: "Angle", value: .angle(angleDegrees(a, b)), points: [])
        }
        if case .vertex(_, let a) = first, case .vertex(_, let b) = second {
            let distance = Double(simd_length(b.simdVector - a.simdVector))
            return SmartMeasurementResult(label: "Distance", value: .length(distance), points: [a, b])
        }
        guard let distance = try? asset.distance(from: entity(for: first), to: entity(for: second)) else { return nil }
        return SmartMeasurementResult(
            label: "Distance",
            value: .length(distance.distance),
            points: [distance.pointOnFaceA.sceneVector, distance.pointOnFaceB.sceneVector]
        )
    }

    private func entity(for target: SmartSelectionTarget) -> CADMeasureEntity {
        switch target {
        case .vertex(_, let position):
            CADMeasureEntity(
                kind: UInt8(CADMeasureEntityKindPoint.rawValue), index: 0,
                point: CADPoint3D(x: Double(position.x), y: Double(position.y), z: Double(position.z))
            )
        case .edge(let index, _):
            CADMeasureEntity(kind: UInt8(CADMeasureEntityKindEdge.rawValue), index: UInt32(index), point: CADPoint3D())
        case .face(let index, _):
            CADMeasureEntity(kind: UInt8(CADMeasureEntityKindFace.rawValue), index: UInt32(index), point: CADPoint3D())
        }
    }

    /// A characteristic direction: the normal of a plane or of a circle's
    /// plane, or the axis of a cylinder/cone/torus or a line.
    private struct Direction {
        enum Kind { case normal, axis }
        let vector: SIMD3<Double>
        let kind: Kind

        var normalized: Direction? {
            let length = simd_length(vector)
            guard length > 1e-9 else { return nil }
            return Direction(vector: vector / length, kind: kind)
        }
    }

    private func direction(of target: SmartSelectionTarget) -> Direction? {
        switch target {
        case .vertex:
            return nil
        case .edge(let index, _):
            let edge = asset.edges[index]
            switch UInt32(edge.curveType) {
            case CADCurveTypeLine.rawValue:
                return Direction(vector: edge.direction.simdDouble, kind: .axis).normalized
            case CADCurveTypeCircle.rawValue:
                return Direction(vector: edge.direction.simdDouble, kind: .normal).normalized
            default:
                return nil
            }
        case .face(let index, _):
            let face = asset.faceRanges[index]
            switch UInt32(face.surfaceType) {
            case CADSurfaceTypePlane.rawValue:
                return Direction(vector: face.axisDirection.simdDouble, kind: .normal).normalized
            case CADSurfaceTypeCylinder.rawValue, CADSurfaceTypeCone.rawValue, CADSurfaceTypeTorus.rawValue:
                return Direction(vector: face.axisDirection.simdDouble, kind: .axis).normalized
            default:
                return nil
            }
        }
    }

    /// Onshape-style: parallel reads 0°, perpendicular 90°. Plane vs plane and
    /// axis vs axis compare their directions; plane vs axis is the angle
    /// between the axis and the plane.
    private func angleDegrees(_ a: Direction, _ b: Direction) -> Double {
        let dot = min(1, abs(simd_dot(a.vector, b.vector)))
        let radians = a.kind == b.kind ? acos(dot) : asin(dot)
        return radians * 180 / .pi
    }
}

extension CADPoint3D {
    var simdDouble: SIMD3<Double> { SIMD3<Double>(x, y, z) }
}

enum CADValueFormatter {
    private static func fractionDigits(for unit: CADLengthUnit) -> Int {
        CADPreferences.measurementPrecision.fractionDigits ?? unit.fractionDigits
    }

    private static func formatter(for unit: CADLengthUnit) -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.maximumFractionDigits = fractionDigits(for: unit)
        formatter.minimumFractionDigits = 0
        return formatter
    }

    private static func number(_ value: Double, unit: CADLengthUnit) -> String {
        formatter(for: unit).string(from: NSNumber(value: value)) ?? String(format: "%.\(fractionDigits(for: unit))f", value)
    }

    /// `value` is in model millimetres.
    static func length(_ value: Double) -> String {
        let unit = CADPreferences.lengthUnit
        return "\(number(value * unit.scale, unit: unit)) \(unit.symbol)"
    }

    /// `value` is in model square millimetres.
    static func area(_ value: Double) -> String {
        let unit = CADPreferences.lengthUnit
        return "\(number(value * unit.scale * unit.scale, unit: unit)) \(unit.symbol)²"
    }

    static func point(_ point: SCNVector3) -> String {
        let unit = CADPreferences.lengthUnit
        return [point.x, point.y, point.z]
            .map { number(Double($0) * unit.scale, unit: unit) }
            .joined(separator: ", ")
    }

    static func angle(_ degrees: Double) -> String {
        String(format: "%.\(CADPreferences.measurementPrecision.fractionDigits ?? 2)f°", degrees)
    }
}
