import Foundation
import SceneKit
import simd

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

/// Load progress reported while a model is being imported and tessellated.
struct CADLoadProgress: Sendable, Equatable {
    enum Stage: Sendable { case reading, translating, meshing, buildingMesh, samplingEdges, finishing }
    let stage: Stage
    /// 0...1, or nil when the stage has no measurable progress.
    let fraction: Double?
    /// Number of faces/edges in the stage when known.
    let count: Int

    var title: String {
        switch stage {
        case .reading: "Reading file"
        case .translating: "Translating B-Rep"
        case .meshing: count > 0 ? "Tessellating \(count.formatted()) faces" : "Tessellating faces"
        case .buildingMesh: "Building display mesh"
        case .samplingEdges: count > 0 ? "Sampling \(count.formatted()) edges" : "Sampling edges"
        case .finishing: "Finishing"
        }
    }
}

private final class CADProgressRelay: @unchecked Sendable {
    let handler: @Sendable (CADLoadProgress) -> Void
    init(_ handler: @escaping @Sendable (CADLoadProgress) -> Void) { self.handler = handler }
}

/// Tessellation density. Thumbnails are tiny, so they trade detail for load
/// time; the viewer and Quick Look preview use the full-quality mesh.
enum CADMeshQuality {
    case thumbnail
    case full

    fileprivate var options: CADMeshOptions {
        var options = CADBridgeDefaultMeshOptions()
        options.parallel = 1
        if case .thumbnail = self {
            options.healShapes = 0
            options.angularDeflectionRadians = 0.4
            options.linearDeflection = 0 // automatic, but see edgeDeflection
            options.linearDeflectionScale = 3
        }
        return options
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

    /// Position/normal sources over the shared vertex buffer, built once and
    /// reused by the surface node and every face-highlight geometry (building
    /// them per hover copied the whole vertex buffer each mouse move).
    private(set) lazy var surfaceGeometrySources: [SCNGeometrySource] = {
        guard !vertices.isEmpty else { return [] }
        let vertexData = vertices.withUnsafeBytes { Data($0) }
        let stride = MemoryLayout<CADVertex>.stride
        let positions = SCNGeometrySource(
            data: vertexData, semantic: .vertex, vectorCount: vertices.count,
            usesFloatComponents: true, componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0, dataStride: stride
        )
        let normals = SCNGeometrySource(
            data: vertexData, semantic: .normal, vectorCount: vertices.count,
            usesFloatComponents: true, componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size, dataOffset: MemoryLayout<Float>.size * 3, dataStride: stride
        )
        return [positions, normals]
    }()

    /// Edge polyline points as floats, in the same order as `polylinePoints`.
    private(set) lazy var polylineSimd: [SIMD3<Float>] = polylinePoints.map {
        SIMD3<Float>(Float($0.x), Float($0.y), Float($0.z))
    }

    /// B-Rep vertices, derived from the end points of every exact edge
    /// polyline and de-duplicated on a tolerance grid (O(n); large STEP
    /// assemblies have tens of thousands of edges). These are the only snap
    /// targets for point-to-point measurement.
    private(set) lazy var topologicalVertices: [SCNVector3] = {
        let minimum = bounds.minimum.sceneVector.simdVector
        let maximum = bounds.maximum.sceneVector.simdVector
        let diagonal = max(simd_length(maximum - minimum), 1)
        let cell = diagonal * 1e-5
        let points = polylineSimd
        var seen = Set<SIMD3<Int32>>()
        var vertices: [SCNVector3] = []
        vertices.reserveCapacity(edges.count)
        for edge in edges {
            let first = Int(edge.firstPoint)
            let count = Int(edge.pointCount)
            guard count > 0, first + count <= points.count else { continue }
            for candidate in [points[first], points[first + count - 1]] {
                let key = SIMD3<Int32>((candidate - minimum) / cell, rounding: .toNearestOrEven)
                if seen.insert(key).inserted {
                    vertices.append(SCNVector3(candidate))
                }
            }
        }
        return vertices
    }()

    /// True for 2D drawings (DXF): the viewer locks to a top-down orthographic
    /// view and there are no faces.
    let isPlanar: Bool

    /// Open CASCADE model, or nil for drawings parsed in Swift.
    private let handle: OpaquePointer?

    init(
        url: URL,
        quality: CADMeshQuality = .full,
        progress: (@Sendable (CADLoadProgress) -> Void)? = nil
    ) throws {
        self.url = url

        if url.pathExtension.lowercased() == "dxf" {
            progress?(CADLoadProgress(stage: .reading, fraction: nil, count: 0))
            let drawing = try DXFDrawing(url: url)
            let scale = drawing.unitScaleToMillimeters
            var points: [CADPoint3D] = []
            var edges: [CADEdgePolyline] = []
            var minimum = SIMD2<Double>(.greatestFiniteMagnitude, .greatestFiniteMagnitude)
            var maximum = SIMD2<Double>(-.greatestFiniteMagnitude, -.greatestFiniteMagnitude)
            for edge in drawing.edges {
                let first = UInt32(points.count)
                for point in edge.points {
                    let scaled = point * scale
                    points.append(CADPoint3D(x: scaled.x, y: scaled.y, z: 0))
                    minimum = simd_min(minimum, scaled)
                    maximum = simd_max(maximum, scaled)
                }
                edges.append(CADEdgePolyline(
                    firstPoint: first,
                    pointCount: UInt32(edge.points.count),
                    exactLength: edge.length * scale,
                    isCircular: edge.isCircular ? 1 : 0,
                    exactDiameter: edge.diameter * scale
                ))
            }
            handle = nil
            isPlanar = true
            vertices = []
            triangles = []
            faceRanges = []
            polylinePoints = points
            self.edges = edges
            bounds = CADBounds(
                minimum: CADPoint3D(x: minimum.x, y: minimum.y, z: 0),
                maximum: CADPoint3D(x: maximum.x, y: maximum.y, z: 0),
                isValid: 1
            )
            var stats = CADModelStats()
            stats.edgeCount = UInt32(edges.count)
            stats.vertexCount = UInt32(edges.count * 2)
            self.stats = stats
            progress?(CADLoadProgress(stage: .finishing, fraction: nil, count: 0))
            return
        }

        guard let model = CADBridgeModelCreate() else {
            throw CADModelError.createFailed
        }
        handle = model
        isPlanar = false

        var relay: Unmanaged<CADProgressRelay>?
        if let progress {
            let box = Unmanaged.passRetained(CADProgressRelay(progress))
            relay = box
            CADBridgeModelSetProgressCallback(model, { context, stage, fraction, count in
                guard let context else { return }
                let relay = Unmanaged<CADProgressRelay>.fromOpaque(context).takeUnretainedValue()
                let mapped: CADLoadProgress.Stage = switch stage {
                case CADLoadStageReading: .reading
                case CADLoadStageTranslating: .translating
                case CADLoadStageMeshing: .meshing
                case CADLoadStageBuildingMesh: .buildingMesh
                case CADLoadStageSamplingEdges: .samplingEdges
                default: .finishing
                }
                relay.handler(CADLoadProgress(stage: mapped, fraction: fraction >= 0 ? fraction : nil, count: Int(count)))
            }, box.toOpaque())
        }
        defer {
            CADBridgeModelSetProgressCallback(model, nil, nil)
            relay?.release()
        }

        let options = quality.options
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
        if let handle { CADBridgeModelDestroy(handle) }
    }

    /// Exact B-Rep face area, computed by Open CASCADE on first request.
    func faceArea(_ index: Int) -> Double {
        guard let handle else { return faceRanges.indices.contains(index) ? max(faceRanges[index].exactArea, 0) : 0 }
        var area = 0.0
        _ = CADBridgeModelFaceArea(handle, UInt32(index), &area)
        return area
    }

    /// Exact B-Rep edge length, computed by Open CASCADE on first request.
    func edgeLength(_ index: Int) -> Double {
        guard let handle else { return edges.indices.contains(index) ? max(edges[index].exactLength, 0) : 0 }
        var length = 0.0
        _ = CADBridgeModelEdgeLength(handle, UInt32(index), &length)
        return length
    }

    func distance(faceA: Int, faceB: Int) throws -> CADFaceDistance {
        guard let handle else { throw CADModelError.loadFailed("Drawings have no faces to measure between.") }
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
