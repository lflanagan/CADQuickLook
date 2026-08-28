import Foundation
import SceneKit

enum SmartSelectionTarget: Equatable {
    case edge(index: Int, position: SCNVector3)
    case face(index: Int, position: SCNVector3)

    static func == (lhs: SmartSelectionTarget, rhs: SmartSelectionTarget) -> Bool {
        switch (lhs, rhs) {
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

struct SmartMeasurementResult {
    let kind: SmartMeasurementKind
    let title: String
    let primaryLabel: String
    let primaryValue: String
    let secondaryLabel: String?
    let secondaryValue: String?
    let detail: String?
    let points: [SCNVector3]
}

@MainActor
final class SmartMeasurementSession {
    var onResult: ((SmartMeasurementResult?) -> Void)?

    private let asset: CADModelAsset
    private var selectedResult: SmartMeasurementResult?
    private var pendingPoint: SCNVector3?
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
            pendingPoint = nil
            pendingFaceIndex = nil
            selectedResult = measurement(for: target, isHover: false)
        case .face(let index, let point):
            if let first = pendingPoint, let firstFaceIndex = pendingFaceIndex {
                let dx = Double(point.x - first.x)
                let dy = Double(point.y - first.y)
                let dz = Double(point.z - first.z)
                let pickedDistance = sqrt(dx * dx + dy * dy + dz * dz)
                if let faceDistance = try? asset.distance(faceA: firstFaceIndex, faceB: index) {
                    selectedResult = SmartMeasurementResult(
                        kind: .pointToPoint,
                        title: "Face to face",
                        primaryLabel: "Minimum",
                        primaryValue: CADValueFormatter.length(faceDistance.distance),
                        secondaryLabel: "Picked points",
                        secondaryValue: CADValueFormatter.length(pickedDistance),
                        detail: "Exact B-Rep minimum and point-to-point distance",
                        points: [faceDistance.pointOnFaceA.sceneVector, faceDistance.pointOnFaceB.sceneVector]
                    )
                } else {
                    selectedResult = SmartMeasurementResult(
                        kind: .pointToPoint,
                        title: "Point to point",
                        primaryLabel: "Distance",
                        primaryValue: CADValueFormatter.length(pickedDistance),
                        secondaryLabel: nil,
                        secondaryValue: nil,
                        detail: "Select another face or edge to inspect it",
                        points: [first, point]
                    )
                }
                pendingPoint = nil
                pendingFaceIndex = nil
            } else {
                pendingPoint = point
                pendingFaceIndex = index
                let faceResult = measurement(for: .face(index: index, position: point), isHover: false)
                selectedResult = SmartMeasurementResult(
                    kind: faceResult.kind,
                    title: faceResult.title,
                    primaryLabel: faceResult.primaryLabel,
                    primaryValue: faceResult.primaryValue,
                    secondaryLabel: nil,
                    secondaryValue: nil,
                    detail: "Point 1 set · click another surface for distance",
                    points: [point]
                )
            }
        }
        onResult?(selectedResult)
    }

    private func measurement(for target: SmartSelectionTarget, isHover: Bool) -> SmartMeasurementResult {
        switch target {
        case .edge(let index, _):
            let edge = asset.edges[index]
            if edge.isCircular != 0 {
                return SmartMeasurementResult(
                    kind: .diameter,
                    title: "Circular edge \(index + 1)",
                    primaryLabel: "Diameter",
                    primaryValue: CADValueFormatter.length(edge.exactDiameter),
                    secondaryLabel: "Length",
                    secondaryValue: CADValueFormatter.length(edge.exactLength),
                    detail: isHover ? "Click to keep this result" : nil,
                    points: []
                )
            }
            return SmartMeasurementResult(
                kind: .edge,
                title: "Edge \(index + 1)",
                primaryLabel: "Length",
                primaryValue: CADValueFormatter.length(edge.exactLength),
                secondaryLabel: nil,
                secondaryValue: nil,
                detail: isHover ? "Click to keep this result" : nil,
                points: []
            )
        case .face(let index, _):
            let face = asset.faceRanges[index]
            return SmartMeasurementResult(
                kind: .faceArea,
                title: "Face \(index + 1)",
                primaryLabel: "Surface area",
                primaryValue: CADValueFormatter.area(face.exactArea),
                secondaryLabel: nil,
                secondaryValue: nil,
                detail: isHover ? "Click to set the first measurement point" : nil,
                points: []
            )
        }
    }
}

enum CADValueFormatter {
    private static let formatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 3
        formatter.minimumFractionDigits = 0
        return formatter
    }()

    static func length(_ value: Double) -> String { format(value, suffix: "mm") }
    static func area(_ value: Double) -> String { format(value, suffix: "mm²") }
    private static func format(_ value: Double, suffix: String) -> String {
        "\(formatter.string(from: NSNumber(value: value)) ?? String(format: "%.3f", value)) \(suffix)"
    }
}
