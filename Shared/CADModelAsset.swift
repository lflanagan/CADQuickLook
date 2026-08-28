import Foundation
import SceneKit

enum CADModelError: LocalizedError {
    case createFailed
    case loadFailed(String)

    var errorDescription: String? {
        switch self {
        case .createFailed:
            return "Could not create the CAD importer."
        case .loadFailed(let message):
            return message
        }
    }
}

final class CADModelAsset: @unchecked Sendable {
    let url: URL
    let vertices: [CADVertex]
    let triangles: [CADTriangle]
    let faceRanges: [CADFaceRange]
    let polylinePoints: [CADPoint3D]
    let edges: [CADEdgePolyline]
    let bounds: CADBounds
    let stats: CADModelStats

    private let handle: OpaquePointer

    init(url: URL) throws {
        guard let model = CADBridgeModelCreate() else {
            throw CADModelError.createFailed
        }
        handle = model
        self.url = url

        var options = CADBridgeDefaultMeshOptions()
        options.parallel = 1
        let status = url.path.withCString { path in
            CADBridgeModelLoad(model, path, options)
        }

        guard status == CADBridgeStatusOK else {
            let detail = CADBridgeModelLastError(model).map { String(cString: $0) }
                ?? "The CAD file could not be imported."
            CADBridgeModelDestroy(model)
            throw CADModelError.loadFailed(detail)
        }

        vertices = Self.copy(CADBridgeModelVertices(model), count: CADBridgeModelVertexCount(model))
        triangles = Self.copy(CADBridgeModelTriangles(model), count: CADBridgeModelTriangleCount(model))
        faceRanges = Self.copy(CADBridgeModelFaceRanges(model), count: CADBridgeModelFaceCount(model))
        polylinePoints = Self.copy(CADBridgeModelPolylinePoints(model), count: CADBridgeModelPolylinePointCount(model))
        edges = Self.copy(CADBridgeModelEdges(model), count: CADBridgeModelEdgeCount(model))
        bounds = CADBridgeModelBounds(model)
        stats = CADBridgeModelStats(model)
    }

    deinit {
        CADBridgeModelDestroy(handle)
    }

    func distance(faceA: Int, faceB: Int) throws -> CADFaceDistance {
        var result = CADFaceDistance()
        let status = CADBridgeModelMeasureFaceDistance(
            handle,
            UInt32(faceA),
            UInt32(faceB),
            &result
        )
        guard status == CADBridgeStatusOK else {
            let detail = CADBridgeModelLastError(handle).map { String(cString: $0) }
                ?? "The distance between those faces could not be measured."
            throw CADModelError.loadFailed(detail)
        }
        return result
    }

    private static func copy<T>(_ pointer: UnsafePointer<T>?, count: Int) -> [T] {
        guard let pointer, count > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: pointer, count: count))
    }
}

extension CADPoint3D {
    var sceneVector: SCNVector3 {
        SCNVector3(Float(x), Float(y), Float(z))
    }
}
