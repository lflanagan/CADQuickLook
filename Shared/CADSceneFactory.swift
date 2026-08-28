import AppKit
import SceneKit
import simd

enum CADSceneFactory {
    static let surfaceNodeName = "CADSurface"
    static let edgeNodeName = "CADEdges"

    static func makeScene(for asset: CADModelAsset) -> SCNScene {
        let scene = SCNScene()
        scene.background.contents = NSColor.clear
        let modelRoot = SCNNode()
        modelRoot.name = "CADModel"
        scene.rootNode.addChildNode(modelRoot)

        if let surface = makeSurfaceNode(asset) {
            modelRoot.addChildNode(surface)
        }
        if let edges = makeEdgeNode(asset) {
            modelRoot.addChildNode(edges)
        }
        modelRoot.addChildNode(makeOriginNode(for: asset))

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

        let vertexData = asset.vertices.withUnsafeBytes { Data($0) }
        let stride = MemoryLayout<CADVertex>.stride
        let positions = SCNGeometrySource(
            data: vertexData,
            semantic: .vertex,
            vectorCount: asset.vertices.count,
            usesFloatComponents: true,
            componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: stride
        )
        let normals = SCNGeometrySource(
            data: vertexData,
            semantic: .normal,
            vectorCount: asset.vertices.count,
            usesFloatComponents: true,
            componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: MemoryLayout<Float>.size * 3,
            dataStride: stride
        )

        let elements: [SCNGeometryElement] = asset.faceRanges.map { range in
            let first = Int(range.firstTriangle)
            let count = Int(range.triangleCount)
            var indices: [UInt32] = []
            indices.reserveCapacity(count * 3)
            if count > 0, first + count <= asset.triangles.count {
                for triangle in asset.triangles[first..<(first + count)] {
                    indices.append(triangle.i0)
                    indices.append(triangle.i1)
                    indices.append(triangle.i2)
                }
            }
            let data = indices.withUnsafeBytes { Data($0) }
            return SCNGeometryElement(
                data: data,
                primitiveType: .triangles,
                primitiveCount: count,
                bytesPerIndex: MemoryLayout<UInt32>.size
            )
        }

        let geometry = SCNGeometry(sources: [positions, normals], elements: elements)
        let material = SCNMaterial()
        material.name = "Machined aluminum"
        material.diffuse.contents = NSColor(calibratedRed: 0.52, green: 0.66, blue: 0.76, alpha: 1)
        material.metalness.contents = 0.35
        material.roughness.contents = 0.42
        material.isDoubleSided = true
        geometry.materials = Array(repeating: material, count: max(elements.count, 1))

        let node = SCNNode(geometry: geometry)
        node.name = surfaceNodeName
        node.categoryBitMask = 1
        return node
    }

    private static func makeEdgeNode(_ asset: CADModelAsset) -> SCNNode? {
        guard !asset.polylinePoints.isEmpty, !asset.edges.isEmpty else { return nil }
        let points = asset.polylinePoints.map(\.sceneVector)
        let source = SCNGeometrySource(vertices: points)
        var elements: [SCNGeometryElement] = []
        elements.reserveCapacity(asset.edges.count)

        for edge in asset.edges {
            let first = Int(edge.firstPoint)
            let count = Int(edge.pointCount)
            var indices: [UInt32] = []
            if count > 1, first + count <= points.count {
                indices.reserveCapacity((count - 1) * 2)
                for offset in 0..<(count - 1) {
                    indices.append(UInt32(first + offset))
                    indices.append(UInt32(first + offset + 1))
                }
            }
            let data = indices.withUnsafeBytes { Data($0) }
            elements.append(SCNGeometryElement(
                data: data,
                primitiveType: .line,
                primitiveCount: max(0, count - 1),
                bytesPerIndex: MemoryLayout<UInt32>.size
            ))
        }

        let geometry = SCNGeometry(sources: [source], elements: elements)
        let material = SCNMaterial()
        material.diffuse.contents = NSColor(calibratedWhite: 0.12, alpha: 0.9)
        material.lightingModel = .constant
        geometry.materials = Array(repeating: material, count: max(elements.count, 1))
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

    private static func makeOriginNode(for asset: CADModelAsset) -> SCNNode {
        let root = SCNNode()
        root.name = "CADOrigin"
        root.categoryBitMask = 4

        let pivot = orbitPivot(for: asset)
        let modelRadius = fittingRadius(for: asset, around: pivot)
        let axisLength = max(modelRadius * 0.22, 0.5)
        let axisRadius = max(axisLength * 0.018, 0.012)

        let originMaterial = SCNMaterial()
        originMaterial.diffuse.contents = NSColor(calibratedWhite: 0.94, alpha: 1)
        originMaterial.emission.contents = NSColor(calibratedWhite: 0.30, alpha: 1)
        originMaterial.lightingModel = .constant
        originMaterial.readsFromDepthBuffer = false
        originMaterial.writesToDepthBuffer = false
        let marker = SCNSphere(radius: axisRadius * 1.7)
        marker.segmentCount = 16
        marker.materials = [originMaterial]
        let markerNode = SCNNode(geometry: marker)
        markerNode.renderingOrder = 100
        root.addChildNode(markerNode)

        addOriginAxis(
            label: "X",
            direction: SIMD3<Float>(1, 0, 0),
            length: axisLength,
            radius: axisRadius,
            color: .systemRed,
            to: root
        )
        addOriginAxis(
            label: "Y",
            direction: SIMD3<Float>(0, 1, 0),
            length: axisLength,
            radius: axisRadius,
            color: .systemGreen,
            to: root
        )
        addOriginAxis(
            label: "Z",
            direction: SIMD3<Float>(0, 0, 1),
            length: axisLength,
            radius: axisRadius,
            color: .systemBlue,
            to: root
        )
        return root
    }

    private static func addOriginAxis(
        label: String,
        direction: SIMD3<Float>,
        length: CGFloat,
        radius: CGFloat,
        color: NSColor,
        to root: SCNNode
    ) {
        let material = SCNMaterial()
        material.diffuse.contents = color
        material.emission.contents = color
        material.lightingModel = .constant
        material.readsFromDepthBuffer = false
        material.writesToDepthBuffer = false

        let cylinder = SCNCylinder(radius: radius, height: length)
        cylinder.radialSegmentCount = 8
        cylinder.materials = [material]
        let line = SCNNode(geometry: cylinder)
        line.simdPosition = direction * Float(length * 0.5)
        line.simdOrientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: direction)
        line.categoryBitMask = 4
        line.renderingOrder = 100
        root.addChildNode(line)

        let text = SCNText(string: label, extrusionDepth: radius * 0.12)
        text.font = .systemFont(ofSize: 1, weight: .bold)
        text.flatness = 0.08
        text.materials = [material]
        let textNode = SCNNode(geometry: text)
        textNode.simdPosition = direction * Float(length * 1.13)
        let labelScale = axisLengthLabelScale(length)
        textNode.scale = SCNVector3(labelScale, labelScale, labelScale)
        let bounds = textNode.boundingBox
        textNode.pivot = SCNMatrix4MakeTranslation(
            (bounds.min.x + bounds.max.x) * 0.5,
            (bounds.min.y + bounds.max.y) * 0.5,
            0
        )
        let billboard = SCNBillboardConstraint()
        billboard.freeAxes = .all
        textNode.constraints = [billboard]
        textNode.categoryBitMask = 4
        textNode.renderingOrder = 101
        root.addChildNode(textNode)
    }

    private static func axisLengthLabelScale(_ axisLength: CGFloat) -> CGFloat {
        axisLength * 0.22
    }

    static func orbitPivot(for asset: CADModelAsset) -> SCNVector3 {
        guard asset.stats.solidCount > 1 || asset.stats.shellCount > 1 else { return SCNVector3Zero }
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

    private static func addCamera(to scene: SCNScene, asset: CADModelAsset) {
        let pivot = orbitPivot(for: asset)
        let fittingRadius = fittingRadius(for: asset, around: pivot)

        let target = SCNNode()
        target.name = "CameraTarget"
        target.position = pivot
        scene.rootNode.addChildNode(target)

        let camera = SCNNode()
        camera.name = "Camera"
        camera.camera = SCNCamera()
        camera.camera?.fieldOfView = 38
        camera.camera?.automaticallyAdjustsZRange = true
        let direction = SCNVector3(1.25, -0.9, 1.45)
        let directionLength = sqrt(direction.x * direction.x + direction.y * direction.y + direction.z * direction.z)
        let distance = fittingRadius * 3.4
        camera.position = SCNVector3(
            pivot.x + direction.x / directionLength * distance,
            pivot.y + direction.y / directionLength * distance,
            pivot.z + direction.z / directionLength * distance
        )
        let lookAt = SCNLookAtConstraint(target: target)
        lookAt.isGimbalLockEnabled = true
        camera.constraints = [lookAt]
        scene.rootNode.addChildNode(camera)
    }
}
