import AppKit
import SceneKit
import simd

enum CADSceneFactory {
    static let surfaceNodeName = "CADSurface"
    static let edgeNodeName = "CADEdges"
    static let modelNodeName = "CADModel"

    static func makeScene(for asset: CADModelAsset) -> SCNScene {
        let scene = SCNScene()
        scene.background.contents = NSColor.clear
        let modelRoot = SCNNode()
        modelRoot.name = modelNodeName
        scene.rootNode.addChildNode(modelRoot)

        if let surface = makeSurfaceNode(asset) {
            modelRoot.addChildNode(surface)
        }
        if let edges = makeEdgeNode(asset) {
            modelRoot.addChildNode(edges)
        }

        addLighting(to: scene)
        addCamera(to: scene, asset: asset)
        return scene
    }

    static func renderThumbnail(for asset: CADModelAsset, size: CGSize, scale: CGFloat = 2) -> NSImage {
        let scene = makeScene(for: asset)
        let renderer = SCNRenderer(device: nil, options: nil)
        renderer.scene = scene
        renderer.pointOfView = scene.rootNode.childNode(withName: "Camera", recursively: true)
        renderer.autoenablesDefaultLighting = false
        return renderer.snapshot(
            atTime: 0,
            with: CGSize(width: size.width * scale, height: size.height * scale),
            antialiasingMode: .multisampling4X
        )
    }

    private static func makeSurfaceNode(_ asset: CADModelAsset) -> SCNNode? {
        guard !asset.vertices.isEmpty, !asset.triangles.isEmpty else { return nil }

        // A single element for every triangle. SceneKit degrades badly past a
        // few thousand elements per geometry (garbage materials, render-thread
        // crashes), and STEP assemblies easily have 10k+ faces. Triangles are
        // stored face-by-face, so a hit's primitive index maps back to its
        // face through CADTriangle.faceIndex.
        let geometry = SCNGeometry(sources: asset.surfaceGeometrySources, elements: [makeTriangleElement(asset.triangles)])
        let material = SCNMaterial()
        material.name = "Machined aluminum"
        material.diffuse.contents = NSColor(calibratedRed: 0.52, green: 0.66, blue: 0.76, alpha: 1)
        material.metalness.contents = 0.35
        material.roughness.contents = 0.42
        material.isDoubleSided = true
        geometry.materials = [material]

        let node = SCNNode(geometry: geometry)
        node.name = surfaceNodeName
        node.categoryBitMask = 1
        return node
    }

    private static func makeTriangleElement<C: Collection>(_ triangles: C) -> SCNGeometryElement where C.Element == CADTriangle {
        var indices: [UInt32] = []
        indices.reserveCapacity(triangles.count * 3)
        for triangle in triangles {
            indices.append(triangle.i0)
            indices.append(triangle.i1)
            indices.append(triangle.i2)
        }
        let data = indices.withUnsafeBytes { Data($0) }
        return SCNGeometryElement(
            data: data,
            primitiveType: .triangles,
            primitiveCount: triangles.count,
            bytesPerIndex: MemoryLayout<UInt32>.size
        )
    }

    /// Geometry containing only `faceIndex`'s triangles, drawn slightly in
    /// front of the surface so it reads as a highlight over that face.
    static func makeFaceHighlightGeometry(for asset: CADModelAsset, faceIndex: Int) -> SCNGeometry? {
        guard asset.faceRanges.indices.contains(faceIndex) else { return nil }
        let range = asset.faceRanges[faceIndex]
        let first = Int(range.firstTriangle)
        let count = Int(range.triangleCount)
        guard count > 0, first + count <= asset.triangles.count else { return nil }

        let element = makeTriangleElement(asset.triangles[first..<(first + count)])
        let geometry = SCNGeometry(sources: asset.surfaceGeometrySources, elements: [element])
        let material = SCNMaterial()
        material.diffuse.contents = NSColor.systemOrange
        material.emission.contents = NSColor.systemOrange.withAlphaComponent(0.35)
        material.metalness.contents = 0.15
        material.roughness.contents = 0.28
        material.isDoubleSided = true
        material.shaderModifiers = [.geometry: depthBiasModifier(0.002)]
        geometry.materials = [material]
        return geometry
    }

    /// Nudges every vertex a fraction of its depth toward the camera so
    /// coplanar overlays (edge lines, face highlights) win the depth test.
    static func depthBiasModifier(_ amount: Float) -> String {
        """
        #pragma body
        float4 viewPosition = scn_node.modelViewTransform * _geometry.position;
        viewPosition.z += \(amount) * abs(viewPosition.z);
        _geometry.position = scn_node.inverseModelViewTransform * viewPosition;
        """
    }

    private static func makeEdgeNode(_ asset: CADModelAsset) -> SCNNode? {
        guard !asset.polylinePoints.isEmpty, !asset.edges.isEmpty else { return nil }
        let points = asset.polylinePoints.map(\.sceneVector)
        let source = SCNGeometrySource(vertices: points)
        // One line element for every edge (see makeSurfaceNode for why).
        var indices: [UInt32] = []
        indices.reserveCapacity(points.count * 2)
        for edge in asset.edges {
            let first = Int(edge.firstPoint)
            let count = Int(edge.pointCount)
            guard count > 1, first + count <= points.count else { continue }
            for offset in 0..<(count - 1) {
                indices.append(UInt32(first + offset))
                indices.append(UInt32(first + offset + 1))
            }
        }
        let data = indices.withUnsafeBytes { Data($0) }
        let element = SCNGeometryElement(
            data: data,
            primitiveType: .line,
            primitiveCount: indices.count / 2,
            bytesPerIndex: MemoryLayout<UInt32>.size
        )

        let geometry = SCNGeometry(sources: [source], elements: [element])
        let material = SCNMaterial()
        // Drawings have no faces behind the lines, so draw them light on the dark background.
        material.diffuse.contents = asset.isPlanar
            ? NSColor(calibratedWhite: 0.88, alpha: 1)
            : NSColor(calibratedWhite: 0.12, alpha: 0.9)
        material.lightingModel = .constant
        // Edge polylines lie exactly on the faces they bound, so without a
        // depth bias they z-fight and render as broken, stippled lines.
        material.shaderModifiers = [.geometry: depthBiasModifier(0.0012)]
        geometry.materials = [material]
        let node = SCNNode(geometry: geometry)
        node.name = edgeNodeName
        node.categoryBitMask = 2
        return node
    }

    private static func addLighting(to scene: SCNScene) {
        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .directional
        key.light?.intensity = 1_100
        key.eulerAngles = SCNVector3(-0.8, 0.6, 0)
        scene.rootNode.addChildNode(key)

        let fill = SCNNode()
        fill.light = SCNLight()
        fill.light?.type = .directional
        fill.light?.intensity = 500
        fill.eulerAngles = SCNVector3(0.5, -2.2, 0)
        scene.rootNode.addChildNode(fill)

        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 350
        ambient.light?.color = NSColor(calibratedWhite: 0.8, alpha: 1)
        scene.rootNode.addChildNode(ambient)
    }

    static func orbitPivot(for asset: CADModelAsset) -> SCNVector3 {
        // Drawings and multi-body assemblies frame on their bounding box;
        // single parts frame on their origin so the datum stays centred.
        guard asset.isPlanar || asset.stats.solidCount > 1 || asset.stats.shellCount > 1 else { return SCNVector3Zero }
        let minimum = asset.bounds.minimum.sceneVector
        let maximum = asset.bounds.maximum.sceneVector
        return SCNVector3(
            (minimum.x + maximum.x) * 0.5,
            (minimum.y + maximum.y) * 0.5,
            (minimum.z + maximum.z) * 0.5
        )
    }

    static func fittingRadius(for asset: CADModelAsset, around pivot: SCNVector3) -> CGFloat {
        let minimum = asset.bounds.minimum.sceneVector
        let maximum = asset.bounds.maximum.sceneVector
        let xExtent = max(abs(minimum.x - pivot.x), abs(maximum.x - pivot.x))
        let yExtent = max(abs(minimum.y - pivot.y), abs(maximum.y - pivot.y))
        let zExtent = max(abs(minimum.z - pivot.z), abs(maximum.z - pivot.z))
        return max(sqrt(xExtent * xExtent + yExtent * yExtent + zExtent * zExtent), 1)
    }

    /// Distance from the fitting sphere's centre to the camera, in radii.
    static let fittingDistanceFactor: Float = 3.4

    /// Default front-right-top view: camera at +X, -Y, +Z looking at the model.
    static let defaultCameraOffset = simd_normalize(SIMD3<Float>(1.25, -0.9, 1.45))

    /// Orientation for a camera sitting at `offset` from its target, with the
    /// world `up` direction kept vertical on screen. CAD models are Z-up.
    static func cameraOrientation(offset: SIMD3<Float>, up: SIMD3<Float> = SIMD3<Float>(0, 0, 1)) -> simd_quatf {
        let backward = simd_normalize(offset)
        var right = simd_cross(up, backward)
        if simd_length(right) < 1e-5 {
            right = simd_cross(SIMD3<Float>(0, 1, 0), backward)
        }
        right = simd_normalize(right)
        let trueUp = simd_cross(backward, right)
        return simd_normalize(simd_quatf(simd_float3x3(columns: (right, trueUp, backward))))
    }

    static func cameraOrientation(for view: CADStandardView) -> simd_quatf {
        switch view {
        case .isometric: cameraOrientation(offset: SIMD3<Float>(1, -1, 1))
        case .top: cameraOrientation(offset: SIMD3<Float>(0, 0, 1), up: SIMD3<Float>(0, 1, 0))
        case .bottom: cameraOrientation(offset: SIMD3<Float>(0, 0, -1), up: SIMD3<Float>(0, -1, 0))
        case .front: cameraOrientation(offset: SIMD3<Float>(0, -1, 0))
        case .back: cameraOrientation(offset: SIMD3<Float>(0, 1, 0))
        case .left: cameraOrientation(offset: SIMD3<Float>(-1, 0, 0))
        case .right: cameraOrientation(offset: SIMD3<Float>(1, 0, 0))
        }
    }

    private static func addCamera(to scene: SCNScene, asset: CADModelAsset) {
        let pivot = orbitPivot(for: asset)
        let fittingRadius = Float(fittingRadius(for: asset, around: pivot))

        let target = SCNNode()
        target.name = "CameraTarget"
        target.position = pivot
        scene.rootNode.addChildNode(target)

        let camera = SCNNode()
        camera.name = "Camera"
        camera.camera = SCNCamera()
        camera.camera?.fieldOfView = 38
        camera.camera?.automaticallyAdjustsZRange = true
        let distance = fittingRadius * fittingDistanceFactor
        let offset = asset.isPlanar ? SIMD3<Float>(0, 0, 1) : defaultCameraOffset
        camera.simdPosition = target.simdPosition + offset * distance
        camera.simdOrientation = asset.isPlanar ? cameraOrientation(for: .top) : cameraOrientation(offset: defaultCameraOffset)
        if asset.isPlanar || CADPreferences.cameraProjection == .orthographic, let cameraGeometry = camera.camera {
            let fieldOfViewRadians = Float(cameraGeometry.fieldOfView) * .pi / 180
            cameraGeometry.usesOrthographicProjection = true
            cameraGeometry.orthographicScale = Double(distance * tan(fieldOfViewRadians * 0.5))
        }
        scene.rootNode.addChildNode(camera)
    }
}
