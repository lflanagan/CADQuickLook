import AppKit
import SceneKit
import simd

enum CADSceneFactory {
    static let surfaceNodeName = "CADSurface"
    static let edgeNodeName = "CADEdges"
    static let tangentEdgeNodeName = "CADTangentEdges"
    /// Depth-ignoring copies of the edge nodes, shown for "hidden edges visible".
    static let hiddenEdgeNodeName = "CADHiddenEdges"
    static let hiddenTangentEdgeNodeName = "CADHiddenTangentEdges"
    static let modelNodeName = "CADModel"

    static func makeScene(for asset: CADModelAsset, options: CADDisplayOptions = .default) -> SCNScene {
        let scene = SCNScene()
        scene.background.contents = NSColor.clear
        let modelRoot = SCNNode()
        modelRoot.name = modelNodeName
        scene.rootNode.addChildNode(modelRoot)

        if let surface = makeSurfaceNode(asset) {
            modelRoot.addChildNode(surface)
        }
        for tangent in [false, true] {
            guard let edges = makeEdgeNode(asset, tangent: tangent) else { continue }
            modelRoot.addChildNode(edges)
            modelRoot.addChildNode(makeHiddenEdgeNode(from: edges, tangent: tangent))
        }
        if let text = makeTextNode(asset) {
            modelRoot.addChildNode(text)
        }

        addLighting(to: scene)
        addCamera(to: scene, asset: asset)
        apply(options, to: scene)
        return scene
    }

    /// Applies display options to a scene built by `makeScene`. Only material
    /// properties and node visibility change; geometry is never rebuilt.
    static func apply(_ options: CADDisplayOptions, to scene: SCNScene) {
        guard let modelRoot = scene.rootNode.childNode(withName: modelNodeName, recursively: false) else { return }
        let showsEdges = options.shading.showsEdges
        let showsTangent = showsEdges && options.tangentEdges != .removed
        // Wireframe: no surface, so every edge is "visible".
        let wireframe = !options.shading.showsSurface
        let showsHidden = showsEdges && (options.hiddenEdges == .visible || wireframe)
        let tangentFade: CGFloat = options.tangentEdges == .phantom ? 0.32 : 1

        if let surfaceNode = modelRoot.childNode(withName: surfaceNodeName, recursively: false) {
            surfaceNode.isHidden = wireframe
            for surface in surfaceNode.geometry?.materials ?? [] {
                surface.lightingModel = options.shading == .unshaded ? .constant : .blinn
                surface.transparency = options.shading == .translucent ? 0.42 : 1
                surface.transparencyMode = options.shading == .translucent ? .dualLayer : .aOne
                surface.writesToDepthBuffer = options.shading != .translucent
            }
        }
        // Edges are dark on the lit surface; with no surface (wireframe,
        // drawings) they must be light to show on the dark backdrop.
        let hasSurface = modelRoot.childNode(withName: surfaceNodeName, recursively: false) != nil
        let lightEdges = wireframe || !hasSurface
        let edgeColor = NSColor(calibratedWhite: lightEdges ? 0.88 : 0.12, alpha: lightEdges ? 1 : 0.9)
        let hiddenColor = NSColor(calibratedWhite: lightEdges ? 0.88 : 0.12, alpha: lightEdges ? 0.45 : 0.5)
        setEdgeNode(edgeNodeName, in: modelRoot, visible: showsEdges, opacity: 1, color: edgeColor)
        setEdgeNode(tangentEdgeNodeName, in: modelRoot, visible: showsTangent, opacity: tangentFade, color: edgeColor)
        setEdgeNode(hiddenEdgeNodeName, in: modelRoot, visible: showsHidden, opacity: 1, color: hiddenColor)
        setEdgeNode(hiddenTangentEdgeNodeName, in: modelRoot, visible: showsHidden && showsTangent, opacity: tangentFade, color: hiddenColor)
    }

    private static func setEdgeNode(_ name: String, in root: SCNNode, visible: Bool, opacity: CGFloat, color: NSColor) {
        guard let node = root.childNode(withName: name, recursively: false) else { return }
        node.isHidden = !visible
        node.opacity = opacity
        // Drawings keep their layer colours; only the default (last-listed
        // default material, or the single material) follows the shading.
        guard let materials = node.geometry?.materials else { return }
        if materials.count == 1 { materials[0].diffuse.contents = color }
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

        // One element per STEP colour (a single element when the model has
        // none). SceneKit degrades badly past a few thousand elements per
        // geometry (garbage materials, render-thread crashes), and STEP
        // assemblies easily have 10k+ faces, so faces are never elements of
        // their own; the colour groups are capped at a few dozen. A hit's
        // (element, primitive) maps back to its triangle through
        // CADModelAsset.triangleIndex(element:primitive:).
        let groups = asset.surfaceGroups
        let elements = groups.map { group in
            makeTriangleElement(group.triangleIndices.lazy.map { asset.triangles[Int($0)] })
        }
        let geometry = SCNGeometry(sources: asset.surfaceGeometrySources, elements: elements)
        geometry.materials = groups.map { group in
            let material = SCNMaterial()
            if let color = group.color {
                material.name = "STEP colour"
                material.diffuse.contents = NSColor(calibratedRed: CGFloat(color.x), green: CGFloat(color.y), blue: CGFloat(color.z), alpha: 1)
                material.metalness.contents = 0.2
                material.roughness.contents = 0.5
            } else {
                material.name = "Machined aluminum"
                material.diffuse.contents = NSColor(calibratedRed: 0.52, green: 0.66, blue: 0.76, alpha: 1)
                material.metalness.contents = 0.35
                material.roughness.contents = 0.42
            }
            material.isDoubleSided = true
            return material
        }

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

    /// The sharp (`tangent == false`) or tangent edges of the model as one
    /// line geometry, or nil when there are none of that kind.
    private static func makeEdgeNode(_ asset: CADModelAsset, tangent: Bool) -> SCNNode? {
        guard !asset.polylinePoints.isEmpty, !asset.edges.isEmpty else { return nil }
        let points = asset.polylinePoints.map(\.sceneVector)
        let source = SCNGeometrySource(vertices: points)
        // One line element for every edge (see makeSurfaceNode for why).
        // Drawings with layer colours get one element per colour; everything
        // else is a single element in the edge colour.
        var order: [SIMD3<Float>?] = []
        var groups: [SIMD3<Float>?: [UInt32]] = [:]
        let maximumColors = 64
        for (edgeIndex, edge) in asset.edges.enumerated() where (edge.isTangent != 0) == tangent {
            let first = Int(edge.firstPoint)
            let count = Int(edge.pointCount)
            guard count > 1, first + count <= points.count else { continue }
            var color: SIMD3<Float>? = asset.edgeColors.indices.contains(edgeIndex) ? asset.edgeColors[edgeIndex] : nil
            if let c = color, groups[c] == nil, order.count >= maximumColors { color = nil }
            if groups[color] == nil {
                groups[color] = []
                order.append(color)
            }
            for offset in 0..<(count - 1) {
                groups[color]!.append(UInt32(first + offset))
                groups[color]!.append(UInt32(first + offset + 1))
            }
        }
        guard !order.isEmpty else { return nil }
        var elements: [SCNGeometryElement] = []
        var materials: [SCNMaterial] = []
        for color in order {
            let indices = groups[color] ?? []
            let data = indices.withUnsafeBytes { Data($0) }
            elements.append(SCNGeometryElement(
                data: data,
                primitiveType: .line,
                primitiveCount: indices.count / 2,
                bytesPerIndex: MemoryLayout<UInt32>.size
            ))
            let material = SCNMaterial()
            // Drawings have no faces behind the lines, so draw them light on the dark background.
            if let color {
                material.diffuse.contents = NSColor(calibratedRed: CGFloat(color.x), green: CGFloat(color.y), blue: CGFloat(color.z), alpha: 1)
            } else {
                material.diffuse.contents = asset.isPlanar
                    ? NSColor(calibratedWhite: 0.88, alpha: 1)
                    : NSColor(calibratedWhite: 0.12, alpha: 0.9)
            }
            material.lightingModel = .constant
            // Edge polylines lie exactly on the faces they bound, so without a
            // depth bias they z-fight and render as broken, stippled lines.
            material.shaderModifiers = [.geometry: depthBiasModifier(0.0012)]
            materials.append(material)
        }
        let geometry = SCNGeometry(sources: [source], elements: elements)
        geometry.materials = materials
        let node = SCNNode(geometry: geometry)
        node.name = tangent ? tangentEdgeNodeName : edgeNodeName
        node.categoryBitMask = 2
        node.renderingOrder = 10
        return node
    }

    static let textNodeName = "CADText"

    /// Drawing text (TEXT/MTEXT) as flat glyph outlines in the XY plane.
    private static func makeTextNode(_ asset: CADModelAsset) -> SCNNode? {
        guard asset.isPlanar, !asset.drawingTexts.isEmpty else { return nil }
        let root = SCNNode()
        root.name = textNodeName
        let font = NSFont(name: "Helvetica", size: 1) ?? .systemFont(ofSize: 1)
        // Helvetica's cap height, in em; DXF text height is the cap height.
        let capHeight = Double(font.capHeight)
        for text in asset.drawingTexts {
            let lines = text.text.components(separatedBy: "\n")
            let lineSpacing = 1.5 * text.height
            let blockHeight = text.height + Double(lines.count - 1) * lineSpacing
            let anchor = SCNNode()
            anchor.position = SCNVector3(text.position.x, text.position.y, 0)
            anchor.eulerAngles = SCNVector3(0, 0, text.rotation)
            for (lineIndex, line) in lines.enumerated() where !line.isEmpty {
                let geometry = SCNText(string: line, extrusionDepth: 0)
                geometry.font = font
                geometry.flatness = 0.05
                let material = SCNMaterial()
                material.lightingModel = .constant
                material.isDoubleSided = true
                if let color = text.color {
                    material.diffuse.contents = NSColor(calibratedRed: CGFloat(color.x), green: CGFloat(color.y), blue: CGFloat(color.z), alpha: 1)
                } else {
                    material.diffuse.contents = NSColor(calibratedWhite: 0.88, alpha: 1)
                }
                geometry.materials = [material]
                let node = SCNNode(geometry: geometry)
                let scale = text.height / max(capHeight, 0.01)
                let (minBound, maxBound) = geometry.boundingBox
                let width = Double(maxBound.x - minBound.x) * scale
                var x = -Double(minBound.x) * scale
                switch text.horizontalAnchor {
                case 1: x -= width / 2
                case 2: x -= width
                default: break
                }
                // Baseline of the first line sits `blockHeight - height` above the block bottom.
                var y = -Double(lineIndex) * lineSpacing
                switch text.verticalAnchor {
                case 1: y += blockHeight / 2 - text.height
                case 2: y -= text.height
                default: y += blockHeight - text.height
                }
                node.position = SCNVector3(x, y, 0)
                node.scale = SCNVector3(scale, scale, scale)
                anchor.addChildNode(node)
            }
            root.addChildNode(anchor)
        }
        root.categoryBitMask = 2
        root.renderingOrder = 10
        return root
    }

    /// A copy of an edge node that ignores the depth buffer, drawn faintly
    /// beneath the real one so edges behind the surface show through.
    private static func makeHiddenEdgeNode(from edges: SCNNode, tangent: Bool) -> SCNNode {
        let geometry = edges.geometry!.copy() as! SCNGeometry
        let material = SCNMaterial()
        // Hidden edges only ever show through the (opaque) surface, so a
        // half-strength version of the edge colour reads as the classic
        // grey hidden line.
        material.diffuse.contents = NSColor(calibratedWhite: 0.12, alpha: 0.5)
        material.lightingModel = .constant
        material.readsFromDepthBuffer = false
        material.writesToDepthBuffer = false
        geometry.materials = Array(repeating: material, count: max(1, geometry.elements.count))
        let node = SCNNode(geometry: geometry)
        node.name = tangent ? hiddenTangentEdgeNodeName : hiddenEdgeNodeName
        node.categoryBitMask = 2
        node.renderingOrder = 5
        node.isHidden = true
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
