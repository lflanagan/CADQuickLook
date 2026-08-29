import Foundation
import SceneKit

enum SmartSelectionTarget: Equatable {
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

enum SmartMeasurementKind {
    case edge
    case diameter
    case faceArea
    case pointToPoint
}

/// A measured quantity in model millimetres; formatted in the user's unit at display time.
enum SmartMeasurementValue {
    case length(Double)
    case area(Double)
    case point(SCNVector3)

    var formatted: String {
        switch self {
        case .length(let value): CADValueFormatter.length(value)
        case .area(let value): CADValueFormatter.area(value)
        case .point(let point): CADValueFormatter.point(point)
        }
    }
}

struct SmartMeasurementResult {
    let kind: SmartMeasurementKind
    let title: String
    let primaryLabel: String
    let primaryValue: SmartMeasurementValue
    let secondaryLabel: String?
    let secondaryValue: SmartMeasurementValue?
    let detail: String?
    let points: [SCNVector3]
}

@MainActor
final class SmartMeasurementSession {
    var onResult: ((SmartMeasurementResult?) -> Void)?

    private let asset: CADModelAsset
    private var selectedResult: SmartMeasurementResult?
    /// First vertex of a point-to-point measurement.
    private var pendingVertex: (index: Int, position: SCNVector3)?
    /// First face of a face-to-face minimum-distance measurement.
    private var pendingFaceIndex: Int?

    init(asset: CADModelAsset) {
        self.asset = asset
    }

    func hover(_ target: SmartSelectionTarget?) {
        guard let target else {
            onResult?(selectedResult)
            return
        }
        onResult?(measurement(for: target, isHover: true))
    }

    func select(_ target: SmartSelectionTarget) {
        switch target {
        case .edge:
            pendingVertex = nil
            pendingFaceIndex = nil
            selectedResult = measurement(for: target, isHover: false)

        case .vertex(let index, let point):
            pendingFaceIndex = nil
            if let first = pendingVertex, first.index != index {
                let dx = Double(point.x - first.position.x)
                let dy = Double(point.y - first.position.y)
                let dz = Double(point.z - first.position.z)
                selectedResult = SmartMeasurementResult(
                    kind: .pointToPoint,
                    title: "Point to point",
                    primaryLabel: "Distance",
                    primaryValue: .length(sqrt(dx * dx + dy * dy + dz * dz)),
                    secondaryLabel: nil,
                    secondaryValue: nil,
                    detail: nil,
                    points: [first.position, point]
                )
                pendingVertex = nil
            } else {
                pendingVertex = (index, point)
                selectedResult = SmartMeasurementResult(
                    kind: .pointToPoint,
                    title: "Point to point",
                    primaryLabel: "Point 1",
                    primaryValue: .point(point),
                    secondaryLabel: nil,
                    secondaryValue: nil,
                    detail: nil,
                    points: [point]
                )
            }

        case .face(let index, _):
            pendingVertex = nil
            if let firstFaceIndex = pendingFaceIndex, firstFaceIndex != index,
               let faceDistance = try? asset.distance(faceA: firstFaceIndex, faceB: index) {
                selectedResult = SmartMeasurementResult(
                    kind: .pointToPoint,
                    title: "Face to face",
                    primaryLabel: "Minimum",
                    primaryValue: .length(faceDistance.distance),
                    secondaryLabel: nil,
                    secondaryValue: nil,
                    detail: nil,
                    points: [faceDistance.pointOnFaceA.sceneVector, faceDistance.pointOnFaceB.sceneVector]
                )
                pendingFaceIndex = nil
            } else {
                pendingFaceIndex = index
                let faceResult = measurement(for: target, isHover: false)
                selectedResult = SmartMeasurementResult(
                    kind: faceResult.kind,
                    title: faceResult.title,
                    primaryLabel: faceResult.primaryLabel,
                    primaryValue: faceResult.primaryValue,
                    secondaryLabel: nil,
                    secondaryValue: nil,
                    detail: nil,
                    points: []
                )
            }
        }
        onResult?(selectedResult)
    }

    private func measurement(for target: SmartSelectionTarget, isHover: Bool) -> SmartMeasurementResult {
        switch target {
        case .vertex(_, let position):
            return SmartMeasurementResult(
                kind: .pointToPoint,
                title: "Vertex",
                primaryLabel: "Position",
                primaryValue: .point(position),
                secondaryLabel: nil,
                secondaryValue: nil,
                detail: nil,
                points: pendingVertex.map { [$0.position] } ?? []
            )
        case .edge(let index, _):
            let edge = asset.edges[index]
            if edge.isCircular != 0 {
                return SmartMeasurementResult(
                    kind: .diameter,
                    title: "Circular edge \(index + 1)",
                    primaryLabel: "Diameter",
                    primaryValue: .length(edge.exactDiameter),
                    secondaryLabel: "Length",
                    secondaryValue: .length(asset.edgeLength(index)),
                    detail: nil,
                    points: []
                )
            }
            return SmartMeasurementResult(
                kind: .edge,
                title: "Edge \(index + 1)",
                primaryLabel: "Length",
                primaryValue: .length(asset.edgeLength(index)),
                secondaryLabel: nil,
                secondaryValue: nil,
                detail: nil,
                points: []
            )
        case .face(let index, _):
            return SmartMeasurementResult(
                kind: .faceArea,
                title: "Face \(index + 1)",
                primaryLabel: "Surface area",
                primaryValue: .area(asset.faceArea(index)),
                secondaryLabel: nil,
                secondaryValue: nil,
                detail: nil,
                points: []
            )
        }
    }
}

enum CADValueFormatter {
    private static func formatter(for unit: CADLengthUnit) -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.maximumFractionDigits = unit.fractionDigits
        formatter.minimumFractionDigits = 0
        return formatter
    }

    private static func number(_ value: Double, unit: CADLengthUnit) -> String {
        formatter(for: unit).string(from: NSNumber(value: value)) ?? String(format: "%.\(unit.fractionDigits)f", value)
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
}
