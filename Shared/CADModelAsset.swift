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
    enum Stage: Sendable { case queued, openingCache, reading, translating, meshing, buildingMesh, samplingEdges, finishing }
    let stage: Stage
    /// 0...1, or nil when the stage has no measurable progress.
    let fraction: Double?
    /// Number of faces/edges in the stage when known.
    let count: Int

    /// Waiting for another import to finish (the app loads one model at a time).
    static let queued = CADLoadProgress(stage: .queued, fraction: nil, count: 0)

    var title: String {
        switch stage {
        case .queued: "Waiting for another model to finish loading"
        case .openingCache: "Opening cached model"
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

/// Stops an import in progress and caps the memory it may use. Wraps a
/// reference-counted bridge token that is independent of the model, so it can
/// be cancelled from any thread while (or after) the model is destroyed.
final class CADLoadCancellation: @unchecked Sendable {
    fileprivate let token: OpaquePointer?

    init(memoryBudgetBytes: UInt64) {
        token = CADBridgeCancelTokenCreate(memoryBudgetBytes)
    }

    convenience init(quality: CADMeshQuality) {
        self.init(memoryBudgetBytes: quality.memoryBudgetBytes)
    }

    deinit {
        if let token { CADBridgeCancelTokenRelease(token) }
    }

    /// Thread-safe; the load stops at its next check and throws CancellationError.
    func cancel() {
        if let token { CADBridgeCancelTokenCancel(token) }
    }
}

/// Tessellation density. Thumbnails are tiny, so they trade detail for load
/// time; the viewer and Quick Look preview use the full-quality mesh.
enum CADMeshQuality {
    case thumbnail
    case full

    var options: CADMeshOptions {
        var options = CADBridgeDefaultMeshOptions()
        options.parallel = 1
        if case .thumbnail = self {
            options.angularDeflectionRadians = 0.4
            options.linearDeflection = 0 // automatic, but see edgeDeflection
            options.linearDeflectionScale = 3
        }
        return options
    }

    /// Process footprint above which an import stops with a "too complex"
    /// error instead of driving the Mac into swap: half of physical memory
    /// (at least 4 GB) for the viewer and preview, a quarter (at least
    /// 2.5 GB) for thumbnails, which Finder requests in bulk.
    var memoryBudgetBytes: UInt64 {
        let physical = ProcessInfo.processInfo.physicalMemory
        let gigabyte: UInt64 = 1 << 30
        switch self {
        case .full: return max(4 * gigabyte, physical / 2)
        case .thumbnail: return max(5 * gigabyte / 2, physical / 4)
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
    /// Drawings only: per-edge colour (nil = default) and the text entities, in millimetres.
    let edgeColors: [SIMD3<Float>?]
    let drawingTexts: [DXFText]

    /// Triangles grouped by STEP face colour, one group per distinct colour
    /// (nil = the default material). Each group becomes one geometry
    /// element, so a hit's (element, primitive) maps back through
    /// `elementTriangles`.
    struct SurfaceGroup {
        let color: SIMD3<Float>?
        let triangleIndices: [UInt32]
    }

    private(set) lazy var surfaceGroups: [SurfaceGroup] = Self.makeSurfaceGroups(triangles: triangles, faceRanges: faceRanges)

    /// Groups appear in order of first occurrence by triangle index; at most
    /// 48 colours (the most-used), the rest fall back to the default.
    static func makeSurfaceGroups(triangles: [CADTriangle], faceRanges: [CADFaceRange]) -> [SurfaceGroup] {
        let colored = faceRanges.contains { $0.hasColor != 0 }
        guard colored, !triangles.isEmpty else {
            return [SurfaceGroup(color: nil, triangleIndices: Array(0..<UInt32(triangles.count)))]
        }
        // Quantise to 8 bits so near-identical exporter colours share a material.
        func key(_ range: CADFaceRange) -> UInt32? {
            guard range.hasColor != 0 else { return nil }
            let r = UInt32(max(0, min(255, range.red * 255)))
            let g = UInt32(max(0, min(255, range.green * 255)))
            let b = UInt32(max(0, min(255, range.blue * 255)))
            return r << 16 | g << 8 | b
        }
        let maximumColors = 48
        var faceKeys: [UInt32?] = faceRanges.map(key)
        var distinct = Set(faceKeys.compactMap { $0 })
        if distinct.count > maximumColors {
            // Keep the most-used colours; the rest fall back to the default.
            var counts: [UInt32: Int] = [:]
            for (index, range) in faceRanges.enumerated() {
                if let k = faceKeys[index] { counts[k, default: 0] += Int(range.triangleCount) }
            }
            // Ties broken by colour so the choice is deterministic.
            let ranked = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            distinct = Set(ranked.prefix(maximumColors).map(\.key))
            faceKeys = faceKeys.map { $0.flatMap { distinct.contains($0) ? $0 : nil } }
        }
        func color(_ k: UInt32?) -> SIMD3<Float>? {
            k.map { SIMD3<Float>(Float($0 >> 16 & 0xFF), Float($0 >> 8 & 0xFF), Float($0 & 0xFF)) / 255 }
        }
        if let groups = contiguousSurfaceGroups(triangles: triangles, faceRanges: faceRanges, faceKeys: faceKeys) {
            return groups.map { SurfaceGroup(color: color($0.key), triangleIndices: $0.indices) }
        }
        // General case (faces not tiling the triangle array in order).
        var order: [UInt32?] = []
        var buckets: [UInt32?: [UInt32]] = [:]
        for (index, triangle) in triangles.enumerated() {
            let face = Int(triangle.faceIndex)
            let k: UInt32? = faceRanges.indices.contains(face) ? faceKeys[face] : nil
            if buckets[k] == nil {
                buckets[k] = []
                order.append(k)
            }
            buckets[k]!.append(UInt32(index))
        }
        return order.map { SurfaceGroup(color: color($0), triangleIndices: buckets[$0] ?? []) }
    }

    /// The bridge emits each face's triangles contiguously, faces in order.
    /// When the face ranges tile the triangle array that way (checked,
    /// including every triangle's faceIndex), each group's index list is
    /// built from whole face ranges in one pass, with no per-triangle
    /// dictionary lookup. Returns nil when the layout doesn't hold.
    private static func contiguousSurfaceGroups(
        triangles: [CADTriangle], faceRanges: [CADFaceRange], faceKeys: [UInt32?]
    ) -> [(key: UInt32?, indices: [UInt32])]? {
        var groupOfKey: [UInt32?: Int] = [:]
        var keys: [UInt32?] = []
        var sizes: [Int] = []
        var faceGroups = [Int](repeating: -1, count: faceRanges.count)
        var next = 0
        for (face, range) in faceRanges.enumerated() where range.triangleCount > 0 {
            guard Int(range.firstTriangle) == next else { return nil }
            next += Int(range.triangleCount)
            guard next <= triangles.count else { return nil }
            let k = faceKeys[face]
            let group: Int
            if let existing = groupOfKey[k] {
                group = existing
            } else {
                group = keys.count
                groupOfKey[k] = group
                keys.append(k)
                sizes.append(0)
            }
            sizes[group] += Int(range.triangleCount)
            faceGroups[face] = group
        }
        guard next == triangles.count else { return nil }
        let consistent = triangles.withUnsafeBufferPointer { buffer in
            for (face, range) in faceRanges.enumerated() where range.triangleCount > 0 {
                let first = Int(range.firstTriangle)
                let faceIndex = UInt32(face)
                for index in first..<first + Int(range.triangleCount) where buffer[index].faceIndex != faceIndex {
                    return false
                }
            }
            return true
        }
        guard consistent else { return nil }
        var lists = sizes.map { size -> [UInt32] in
            var list: [UInt32] = []
            list.reserveCapacity(size)
            return list
        }
        for (face, range) in faceRanges.enumerated() where range.triangleCount > 0 {
            lists[faceGroups[face]].append(contentsOf: range.firstTriangle..<range.firstTriangle + range.triangleCount)
        }
        return zip(keys, lists).map { (key: $0, indices: $1) }
    }

    /// Global triangle index for a hit on surface element `element`, primitive `primitive`.
    func triangleIndex(element: Int, primitive: Int) -> Int? {
        guard surfaceGroups.indices.contains(element) else { return nil }
        let group = surfaceGroups[element].triangleIndices
        guard group.indices.contains(primitive) else { return nil }
        return Int(group[primitive])
    }

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
    /// A triangle soup (STL): one display face, no B-Rep edges or vertices, so
    /// there is nothing meaningful to pick.
    var isMesh: Bool { url.pathExtension.lowercased() == "stl" }

    /// Open CASCADE model, or nil for drawings parsed in Swift.
    private let handle: OpaquePointer?
    /// Serialises every bridge call on `handle` after init: the display-data
    /// release dispatched at the end of a load, then measurements and
    /// destruction, which wait for it (briefly, only right after a load).
    private let bridgeQueue = DispatchQueue(label: "com.liamflanagan.CADQuickLook.model-bridge")

    init(
        url: URL,
        quality: CADMeshQuality = .full,
        cancellation: CADLoadCancellation? = nil,
        progress: (@Sendable (CADLoadProgress) -> Void)? = nil
    ) throws {
        try Task.checkCancellation()
        self.url = url

        if url.pathExtension.lowercased() == "dxf" {
            progress?(CADLoadProgress(stage: .reading, fraction: nil, count: 0))
            let drawing = try DXFDrawing(url: url)
            // DXF parsing can't be interrupted; at least drop the result early.
            try Task.checkCancellation()
            let scale = drawing.unitScaleToMillimeters
            var points: [CADPoint3D] = []
            var edges: [CADEdgePolyline] = []
            var colors: [SIMD3<Float>?] = []
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
                var polyline = CADEdgePolyline()
                polyline.firstPoint = first
                polyline.pointCount = UInt32(edge.points.count)
                polyline.exactLength = edge.length * scale
                polyline.isCircular = edge.isCircular ? 1 : 0
                polyline.exactDiameter = edge.diameter * scale
                polyline.isTangent = 0
                if edge.isCircular {
                    polyline.curveType = UInt8(CADCurveTypeCircle.rawValue)
                    polyline.direction = CADPoint3D(x: 0, y: 0, z: 1)
                } else if edge.points.count == 2 {
                    let delta = edge.points[1] - edge.points[0]
                    let length = simd_length(delta)
                    if length > 0 {
                        polyline.curveType = UInt8(CADCurveTypeLine.rawValue)
                        polyline.direction = CADPoint3D(x: delta.x / length, y: delta.y / length, z: 0)
                    }
                }
                edges.append(polyline)
                colors.append(edge.color)
            }
            var texts = drawing.texts
            for index in texts.indices {
                texts[index].position *= scale
                texts[index].height *= scale
                let p = texts[index].position
                minimum = simd_min(minimum, p)
                maximum = simd_max(maximum, p)
            }
            edgeColors = colors.contains { $0 != nil } ? colors : []
            drawingTexts = texts
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

        // Model cache: B-Rep formats of at least 2 MB, keyed for the
        // full-quality mesh (thumbnails may read a full entry, never write).
        let cache = CADModelCache.shared
        let cacheOptions = CADMeshQuality.full.options
        let cacheKey = cache?.lookupKey(for: url, options: cacheOptions)
        // Always load (and restore) with a token so the memory budget applies
        // even to callers that never cancel (thumbnails).
        let cancellation = cancellation ?? CADLoadCancellation(quality: quality)

        // The entry's section hashes (shape bytes included) were verified by
        // read(); a damaged shape can otherwise restore "OK" with wrong geometry.
        if let cache, let cacheKey, let entry = cache.read(key: cacheKey) {
            try Task.checkCancellation()
            progress?(CADLoadProgress(stage: .openingCache, fraction: nil, count: 0))
            guard let model = CADBridgeModelCreate() else {
                throw CADModelError.createFailed
            }
            CADBridgeModelSetCancelToken(model, cancellation.token)
            let status = Self.restore(model, from: entry)
            CADBridgeModelSetCancelToken(model, nil)
            withExtendedLifetime(cancellation) {}
            switch status {
            case CADBridgeStatusOK:
                break
            case CADBridgeStatusCancelled:
                CADBridgeModelDestroy(model)
                throw CancellationError()
            case CADBridgeStatusResourceLimit:
                // Over budget: a full load would be too, so fail like one would.
                // The entry itself is fine; keep it.
                let detail = CADBridgeModelLastError(model).map { String(cString: $0) }
                CADBridgeModelDestroy(model)
                throw CADModelError.loadFailed(detail ?? "This model is too complex to display.")
            case CADBridgeStatusImportFailed:
                // Unparseable or inconsistent with its tables: drop the entry.
                CADBridgeModelDestroy(model)
                cache.remove(key: cacheKey)
            default:
                CADBridgeModelDestroy(model)
            }
            if status == CADBridgeStatusOK {
                if Task.isCancelled {
                    CADBridgeModelDestroy(model)
                    throw CancellationError()
                }
                handle = model
                isPlanar = false
                vertices = entry.vertices
                triangles = entry.triangles
                faceRanges = entry.faceRanges
                polylinePoints = entry.polylinePoints
                edges = entry.edges
                bounds = entry.bounds
                stats = entry.stats
                edgeColors = []
                drawingTexts = []
                progress?(CADLoadProgress(stage: .finishing, fraction: nil, count: 0))
                return
            }
            // ImportFailed or an unexpected status: load the file normally.
        }

        guard let model = CADBridgeModelCreate() else {
            throw CADModelError.createFailed
        }
        handle = model
        isPlanar = false

        CADBridgeModelSetCancelToken(model, cancellation.token)

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

        let options = quality.options
        let loadStarted = ContinuousClock.now
        let status = url.path.withCString { path in
            CADBridgeModelLoad(model, path, options)
        }
        let loadDuration = ContinuousClock.now - loadStarted
        let loadSeconds = Double(loadDuration.components.seconds) + Double(loadDuration.components.attoseconds) / 1e18

        // Detach the callback and token before anything below can destroy the
        // model (a throwing init never runs deinit, so the failure path
        // destroys it here; a `defer` would touch the freed model).
        CADBridgeModelSetProgressCallback(model, nil, nil)
        CADBridgeModelSetCancelToken(model, nil)
        relay?.release()
        withExtendedLifetime(cancellation) {}

        guard status == CADBridgeStatusOK else {
            let detail = CADBridgeModelLastError(model).map { String(cString: $0) }
            CADBridgeModelDestroy(model)
            switch status {
            case CADBridgeStatusCancelled:
                throw CancellationError()
            case CADBridgeStatusResourceLimit:
                throw CADModelError.loadFailed(detail ?? "This model is too complex to display.")
            default:
                throw CADModelError.loadFailed(detail ?? "The CAD file could not be imported.")
            }
        }

        // A slow full-quality load qualifies for the cache: take the B-Rep
        // bytes now (cheap next to the load); compression and the write run
        // in the background once the asset exists. NULL (no shape) means no
        // entry. The bytes vary between copies, so they are never a key.
        var shapeData: Data?
        if quality == .full, cacheKey != nil, loadSeconds > CADModelCache.minimumLoadSeconds {
            shapeData = Self.copyShapeData(model)
        }

        vertices = Self.copy(CADBridgeModelVertices(model), count: CADBridgeModelVertexCount(model))
        triangles = Self.copy(CADBridgeModelTriangles(model), count: CADBridgeModelTriangleCount(model))
        faceRanges = Self.copy(CADBridgeModelFaceRanges(model), count: CADBridgeModelFaceCount(model))
        polylinePoints = Self.copy(CADBridgeModelPolylinePoints(model), count: CADBridgeModelPolylinePointCount(model))
        edges = Self.copy(CADBridgeModelEdges(model), count: CADBridgeModelEdgeCount(model))
        bounds = CADBridgeModelBounds(model)
        stats = CADBridgeModelStats(model)
        edgeColors = []
        drawingTexts = []
        // The arrays above are the only copies the viewer uses; the bridge's
        // originals and Open CASCADE's per-face tessellation would otherwise
        // sit in memory for as long as the model is open. Freeing them takes
        // tens of milliseconds on a large assembly, so it runs on the bridge
        // queue instead of delaying the load; later bridge calls queue behind it.
        let releaseTarget = CADBridgeHandle(pointer: model)
        bridgeQueue.async {
            CADBridgeModelReleaseDisplayData(releaseTarget.pointer)
        }

        if let cache, let cacheKey, let shapeData {
            let entry = CADModelCache.Entry(
                vertices: vertices, triangles: triangles, faceRanges: faceRanges,
                polylinePoints: polylinePoints, edges: edges, bounds: bounds, stats: stats,
                shapeData: shapeData, loadSeconds: loadSeconds
            )
            cache.storeInBackground(entry, key: cacheKey, source: url, options: cacheOptions)
        }
    }

    deinit {
        if let handle {
            bridgeQueue.sync { CADBridgeModelDestroy(handle) }
        }
    }

    /// Rebuilds the bridge model from a cache entry's B-Rep and tables.
    private static func restore(_ model: OpaquePointer, from entry: CADModelCache.Entry) -> CADBridgeStatus {
        entry.shapeData.withUnsafeBytes { shape in
            entry.faceRanges.withUnsafeBufferPointer { faces in
                entry.edges.withUnsafeBufferPointer { edges in
                    guard let base = shape.baseAddress, !shape.isEmpty else { return CADBridgeStatusImportFailed }
                    return CADBridgeModelRestore(
                        model, base.assumingMemoryBound(to: UInt8.self), shape.count,
                        faces.baseAddress, faces.count, edges.baseAddress, edges.count,
                        entry.bounds, entry.stats
                    )
                }
            }
        }
    }

    /// The model's exact B-Rep in the bridge's binary format, or nil.
    private static func copyShapeData(_ model: OpaquePointer) -> Data? {
        var length = 0
        guard let bytes = CADBridgeModelCopyShapeData(model, &length) else { return nil }
        guard length > 0 else {
            CADBridgeFree(bytes)
            return nil
        }
        return Data(bytesNoCopy: bytes, count: length, deallocator: .custom { pointer, _ in CADBridgeFree(pointer) })
    }

    /// Imports off the calling actor. Cancelling the calling task stops the
    /// import through its cancel token (Open CASCADE formats; DXF is parsed
    /// in Swift and only stops between stages) and throws CancellationError.
    static func load(
        url: URL,
        quality: CADMeshQuality = .full,
        progress: (@Sendable (CADLoadProgress) -> Void)? = nil
    ) async throws -> CADModelAsset {
        let cancellation = CADLoadCancellation(quality: quality)
        let task = Task.detached(priority: .userInitiated) {
            try CADModelAsset(url: url, quality: quality, cancellation: cancellation, progress: progress)
        }
        return try await withTaskCancellationHandler {
            let asset = try await task.value
            try Task.checkCancellation()
            return asset
        } onCancel: {
            cancellation.cancel()
            task.cancel()
        }
    }

    /// Exact B-Rep face area, computed by Open CASCADE on first request.
    func faceArea(_ index: Int) -> Double {
        guard let handle else { return faceRanges.indices.contains(index) ? max(faceRanges[index].exactArea, 0) : 0 }
        return bridgeQueue.sync {
            var area = 0.0
            _ = CADBridgeModelFaceArea(handle, UInt32(index), &area)
            return area
        }
    }

    /// Exact B-Rep edge length, computed by Open CASCADE on first request.
    func edgeLength(_ index: Int) -> Double {
        guard let handle else { return edges.indices.contains(index) ? max(edges[index].exactLength, 0) : 0 }
        return bridgeQueue.sync {
            var length = 0.0
            _ = CADBridgeModelEdgeLength(handle, UInt32(index), &length)
            return length
        }
    }

    /// Exact minimum distance between two entities (points, edges, faces in
    /// any combination), with the closest point on each.
    func distance(from a: CADMeasureEntity, to b: CADMeasureEntity) throws -> CADFaceDistance {
        guard let handle else {
            // Drawings: only point-to-point is available, done in Swift.
            guard a.kind == CADMeasureEntityKindPoint.rawValue, b.kind == CADMeasureEntityKindPoint.rawValue else {
                throw CADModelError.loadFailed("Drawings only support point-to-point measurement.")
            }
            let delta = b.point.simdDouble - a.point.simdDouble
            return CADFaceDistance(distance: simd_length(delta), pointOnFaceA: a.point, pointOnFaceB: b.point)
        }
        let (status, result, detail) = bridgeQueue.sync {
            var result = CADFaceDistance()
            let status = CADBridgeModelMeasureDistance(handle, a, b, &result)
            let detail = status == CADBridgeStatusOK ? nil : CADBridgeModelLastError(handle).map { String(cString: $0) }
            return (status, result, detail)
        }
        guard status == CADBridgeStatusOK else {
            throw CADModelError.loadFailed(detail ?? "The distance between those entities could not be measured.")
        }
        return result
    }

    private static func copy<T>(_ pointer: UnsafePointer<T>?, count: Int) -> [T] {
        guard let pointer, count > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: pointer, count: count))
    }
}

/// A bridge model pointer handed to the asset's bridge queue. Only used for
/// calls that the queue serialises.
private struct CADBridgeHandle: @unchecked Sendable {
    let pointer: OpaquePointer
}

extension CADPoint3D {
    var sceneVector: SCNVector3 {
        SCNVector3(Float(x), Float(y), Float(z))
    }
}
