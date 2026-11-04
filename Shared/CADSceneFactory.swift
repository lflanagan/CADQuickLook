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

    /// Vertical field of view of the scene camera, in degrees.
    static let cameraFieldOfView: Double = 38

    /// Nudges every vertex toward the camera so coplanar overlays (edge
    /// lines, face highlights) win the depth test. The nudge is `amount`
    /// of the vertex's depth, which keeps it a constant size on screen in
    /// perspective. In orthographic mode the camera stays far away and
    /// zooming only changes the view height, so a depth-based nudge stays
    /// millimetres thick at any zoom and lets edges behind thin plates
    /// show through. There the nudge scales with the view's half-height
    /// (1 / P[1][1]) instead, at the size it would have in the matching
    /// perspective view (the same half-height at the camera's 38 degrees).
    static func depthBiasModifier(_ amount: Float) -> String {
        let halfFieldOfView = cameraFieldOfView * .pi / 360
        let orthographicAmount = amount / Float(tan(halfFieldOfView))
        return """
        #pragma body
        float4 viewPosition = scn_node.modelViewTransform * _geometry.position;
        float4x4 projection = scn_frame.projectionTransform;
        float bias = (projection[3][3] > 0.5)
            ? \(orthographicAmount) / projection[1][1]
            : \(amount) * abs(viewPosition.z);
        viewPosition.z += bias;
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
        for (edgeIndex, edge) in asset.edges.enumerated() where edge.isHidden == 0 && (edge.isTangent != 0) == tangent {
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

    /// Centre of the model for orbiting: the framing box's centre, so stray
    /// geometry doesn't pull it off the model.
    static func orbitPivot(for asset: CADModelAsset) -> SCNVector3 {
        let box = framingBox(for: asset)
        let center = (box.minimum + box.maximum) * 0.5
        return SCNVector3(center.x, center.y, center.z)
    }

    /// Radius of the framing box's sphere around `pivot`: the model's size,
    /// for scale-dependent sizes such as the axis probe.
    static func fittingRadius(for asset: CADModelAsset, around pivot: SCNVector3) -> CGFloat {
        let box = framingBox(for: asset)
        let minimum = SCNVector3(box.minimum.x, box.minimum.y, box.minimum.z)
        let maximum = SCNVector3(box.maximum.x, box.maximum.y, box.maximum.z)
        let xExtent = max(abs(minimum.x - pivot.x), abs(maximum.x - pivot.x))
        let yExtent = max(abs(minimum.y - pivot.y), abs(maximum.y - pivot.y))
        let zExtent = max(abs(minimum.z - pivot.z), abs(maximum.z - pivot.z))
        return max(sqrt(xExtent * xExtent + yExtent * yExtent + zExtent * zExtent), 1)
    }

    /// Axis-aligned box the camera frames, in scene units.
    struct FramingBox: Equatable, Sendable {
        var minimum: SIMD3<Float>
        var maximum: SIMD3<Float>
    }

    /// The box the camera frames: the model's bounding box with tiny stray
    /// geometry far from the rest left out (a forgotten 1 mm body, a sliver
    /// face), so it doesn't shrink the model in the view. Weighted by surface
    /// area: on each axis, clusters at the ends holding at most 0.5% of the
    /// area and separated from the rest by an empty gap are left out, then
    /// every face holding a meaningful share of the area is added back
    /// whole, so real parts at the edge of an assembly stay in. Drawings and models
    /// without a mesh use their bounding box. Computed once per asset.
    static func framingBox(for asset: CADModelAsset) -> FramingBox {
        if let cached = framingCache.box(for: asset) { return cached }
        let box = computeFramingBox(for: asset)
        framingCache.store(box, for: asset)
        return box
    }

    private static let framingCache = FramingBoxCache()

    private final class FramingBoxCache: @unchecked Sendable {
        final class Entry {
            let box: FramingBox
            init(_ box: FramingBox) { self.box = box }
        }

        private let lock = NSLock()
        private let table = NSMapTable<CADModelAsset, Entry>(
            keyOptions: [.weakMemory, .objectPointerPersonality],
            valueOptions: .strongMemory
        )

        func box(for asset: CADModelAsset) -> FramingBox? {
            lock.withLock { table.object(forKey: asset)?.box }
        }

        func store(_ box: FramingBox, for asset: CADModelAsset) {
            lock.withLock { table.setObject(Entry(box), forKey: asset) }
        }
    }

    private static func computeFramingBox(for asset: CADModelAsset) -> FramingBox {
        let bounds = FramingBox(
            minimum: SIMD3<Float>(Float(asset.bounds.minimum.x), Float(asset.bounds.minimum.y), Float(asset.bounds.minimum.z)),
            maximum: SIMD3<Float>(Float(asset.bounds.maximum.x), Float(asset.bounds.maximum.y), Float(asset.bounds.maximum.z))
        )
        guard !asset.isPlanar, !asset.vertices.isEmpty, !asset.triangles.isEmpty else { return bounds }
        let extent = bounds.maximum - bounds.minimum
        guard extent.x.isFinite, extent.y.isFinite, extent.z.isFinite, simd_reduce_max(extent) > 0 else { return bounds }

        // Area-weighted histogram of triangle centroids on each axis, and
        // the area of each face.
        let binCount = 1024
        let binScale = SIMD3<Float>(repeating: Float(binCount)) / simd_max(extent, SIMD3<Float>(repeating: .leastNormalMagnitude))
        var histogram = [Double](repeating: 0, count: binCount * 3)
        var faceAreas = [Double](repeating: 0, count: asset.faceRanges.count)
        var totalArea = 0.0
        asset.vertices.withUnsafeBufferPointer { vertices in
            asset.triangles.withUnsafeBufferPointer { triangles in
                histogram.withUnsafeMutableBufferPointer { histogram in
                    faceAreas.withUnsafeMutableBufferPointer { faceAreas in
                        let vertexCount = vertices.count
                        let lastBin = SIMD3<Float>(repeating: Float(binCount - 1))
                        for triangle in triangles {
                            let i0 = Int(triangle.i0), i1 = Int(triangle.i1), i2 = Int(triangle.i2)
                            guard i0 < vertexCount, i1 < vertexCount, i2 < vertexCount else { continue }
                            let a = SIMD3<Float>(vertices[i0].x, vertices[i0].y, vertices[i0].z)
                            let b = SIMD3<Float>(vertices[i1].x, vertices[i1].y, vertices[i1].z)
                            let c = SIMD3<Float>(vertices[i2].x, vertices[i2].y, vertices[i2].z)
                            let area = Double(simd_length(simd_cross(b - a, c - a)) * 0.5)
                            guard area > 0, area.isFinite else { continue }
                            totalArea += area
                            let face = Int(triangle.faceIndex)
                            if face < faceAreas.count { faceAreas[face] += area }
                            let bin = simd_clamp(((a + b + c) / 3 - bounds.minimum) * binScale, .zero, lastBin)
                            histogram[Int(bin.x)] += area
                            histogram[binCount + Int(bin.y)] += area
                            histogram[2 * binCount + Int(bin.z)] += area
                        }
                    }
                }
            }
        }
        guard totalArea > 0, totalArea.isFinite else { return bounds }

        // On each axis, drop end clusters holding at most 0.5% of the area
        // that sit beyond an empty gap of at least 5% of the extent: stray
        // bodies away from the model, never the ends of connected geometry.
        let tail = totalArea * 0.005
        let gapBins = binCount / 20
        var box = bounds
        let binSize = extent / Float(binCount)
        for axis in 0..<3 {
            let bins = histogram[(axis * binCount)..<((axis + 1) * binCount)].map { $0 }
            var low = 0
            var high = binCount - 1
            var trimmed = 0.0
            // Trims one cluster from the low (step 1) or high (step -1) end.
            func trimCluster(from start: Int, step: Int) -> Int? {
                var index = start
                var sum = 0.0
                while index >= low, index <= high, bins[index] > 0 {
                    sum += bins[index]
                    index += step
                }
                guard trimmed + sum <= tail else { return nil }
                var gap = 0
                while index >= low, index <= high, bins[index] == 0 {
                    gap += 1
                    index += step
                }
                guard gap >= gapBins, index >= low, index <= high else { return nil }
                trimmed += sum
                return index
            }
            while bins[low] == 0, low < high { low += 1 }
            while bins[high] == 0, high > low { high -= 1 }
            // Sides with nothing to drop keep their true bound.
            var trimmedLow = false
            var trimmedHigh = false
            while let next = trimCluster(from: low, step: 1) { low = next; trimmedLow = true }
            while let next = trimCluster(from: high, step: -1) { high = next; trimmedHigh = true }
            if trimmedLow { box.minimum[axis] = bounds.minimum[axis] + Float(low) * binSize[axis] }
            if trimmedHigh { box.maximum[axis] = bounds.minimum[axis] + Float(high + 1) * binSize[axis] }
        }

        // Add back every face with a meaningful share of the area, whole.
        let significantArea = totalArea * 0.002
        asset.vertices.withUnsafeBufferPointer { vertices in
            asset.triangles.withUnsafeBufferPointer { triangles in
                for (face, range) in asset.faceRanges.enumerated() where faceAreas[face] >= significantArea {
                    let first = Int(range.firstTriangle)
                    let end = min(first + Int(range.triangleCount), triangles.count)
                    guard first < end else { continue }
                    func include(_ index: UInt32) {
                        guard Int(index) < vertices.count else { return }
                        let vertex = vertices[Int(index)]
                        let point = SIMD3<Float>(vertex.x, vertex.y, vertex.z)
                        box.minimum = simd_min(box.minimum, point)
                        box.maximum = simd_max(box.maximum, point)
                    }
                    for triangle in triangles[first..<end] {
                        include(triangle.i0)
                        include(triangle.i1)
                        include(triangle.i2)
                    }
                }
            }
        }

        // Pad a little, never past the true bounds.
        let padding = (box.maximum - box.minimum) * 0.02
        box.minimum = simd_max(box.minimum - padding, bounds.minimum)
        box.maximum = simd_min(box.maximum + padding, bounds.maximum)
        guard simd_reduce_min(box.maximum - box.minimum) >= 0 else { return bounds }
        return box
    }

    /// Where a camera with a given orientation looks from to fit the model.
    struct CameraFit: Sendable {
        /// The look-at point: the centre of the framed view, at the depth
        /// of the framing box's centre.
        var target: SIMD3<Float>
        /// Distance from `target` back to the camera along its view axis.
        var distance: Float
        /// Half the view height, for an orthographic camera.
        var orthographicScale: Double
    }

    /// Room left around the fitted model: its projected half-extent times
    /// this fills half the view.
    static let fittingMargin: Float = 1.08

    /// Fits the model in a view with the camera's `orientation`, the scene
    /// camera's vertical field of view and the viewport's `aspect` (width
    /// over height). Projects every mesh vertex inside the framing box (or
    /// the box's corners for drawings and models without a mesh) onto the
    /// camera's axes, so the model fills the view with `fittingMargin` to
    /// spare and sits in its middle. Perspective cameras get the tightest
    /// frustum containing those points; orthographic ones the tightest
    /// view height. Clipping is unaffected: the camera adjusts its z range
    /// to the whole scene.
    static func cameraFit(
        for asset: CADModelAsset,
        orientation: simd_quatf,
        aspect: Float = 1,
        orthographic: Bool
    ) -> CameraFit {
        let box = framingBox(for: asset)
        let right = orientation.act(SIMD3<Float>(1, 0, 0))
        let up = orientation.act(SIMD3<Float>(0, 1, 0))
        let backward = orientation.act(SIMD3<Float>(0, 0, 1))
        let tanY = Float(tan(cameraFieldOfView * .pi / 360)) / fittingMargin
        let tanX = tanY * (aspect.isFinite && aspect > 0 ? aspect : 1)

        // Extents on the camera axes (x right, y up, z towards the camera),
        // and for perspective the frustum bounds: a point fits the half
        // angle on x when x + tanX*z <= cx + tanX*Zc and x - tanX*z >= cx -
        // tanX*Zc, Zc being the camera's depth.
        var low = SIMD3<Float>(repeating: .infinity)
        var high = SIMD3<Float>(repeating: -.infinity)
        var frustumHigh = SIMD2<Float>(repeating: -.infinity)
        var frustumLow = SIMD2<Float>(repeating: .infinity)
        let tangents = SIMD2<Float>(tanX, tanY)
        func include(_ point: SIMD3<Float>) {
            let projected = SIMD3<Float>(simd_dot(point, right), simd_dot(point, up), simd_dot(point, backward))
            low = simd_min(low, projected)
            high = simd_max(high, projected)
            let lateral = SIMD2<Float>(projected.x, projected.y)
            frustumHigh = simd_max(frustumHigh, lateral + tangents * projected.z)
            frustumLow = simd_min(frustumLow, lateral - tangents * projected.z)
        }
        if !asset.isPlanar, !asset.vertices.isEmpty, !asset.triangles.isEmpty {
            asset.vertices.withUnsafeBufferPointer { vertices in
                for vertex in vertices {
                    let point = SIMD3<Float>(vertex.x, vertex.y, vertex.z)
                    guard all(point .>= box.minimum), all(point .<= box.maximum) else { continue }
                    include(point)
                }
            }
        }
        if !(low.x <= high.x) {
            for corner in 0..<8 {
                include(SIMD3<Float>(
                    corner & 1 == 0 ? box.minimum.x : box.maximum.x,
                    corner & 2 == 0 ? box.minimum.y : box.maximum.y,
                    corner & 4 == 0 ? box.minimum.z : box.maximum.z
                ))
            }
        }
        guard low.x.isFinite, high.x.isFinite else {
            return CameraFit(target: .zero, distance: 10, orthographicScale: 1)
        }

        let size = max(simd_length(high - low), 1e-3)
        let depthCenter = (low.z + high.z) * 0.5
        // Keep the camera clear of the model's near side.
        let minimumDistance = (high.z - depthCenter) + size * 0.25
        let lateralCenter: SIMD2<Float>
        let distance: Float
        let orthographicScale: Float
        if orthographic {
            lateralCenter = (SIMD2<Float>(low.x, low.y) + SIMD2<Float>(high.x, high.y)) * 0.5
            let halfExtent = (SIMD2<Float>(high.x, high.y) - SIMD2<Float>(low.x, low.y)) * 0.5
            orthographicScale = max(max(halfExtent.y / tanY, halfExtent.x / tanX) * Float(tan(cameraFieldOfView * .pi / 360)), size * 1e-3)
            // The camera stays as far back as a perspective camera showing
            // the same height would, as zooming expects.
            distance = max(orthographicScale / Float(tan(cameraFieldOfView * .pi / 360)), minimumDistance)
        } else {
            lateralCenter = (frustumHigh + frustumLow) * 0.5
            let cameraDepth = (frustumHigh - frustumLow) * 0.5 / tangents
            distance = max(max(cameraDepth.x, cameraDepth.y) - depthCenter, minimumDistance)
            orthographicScale = distance * Float(tan(cameraFieldOfView * .pi / 360))
        }
        let target = right * lateralCenter.x + up * lateralCenter.y + backward * depthCenter
        return CameraFit(target: target, distance: distance, orthographicScale: Double(orthographicScale))
    }

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
        let orientation = asset.isPlanar ? cameraOrientation(for: .top) : cameraOrientation(offset: defaultCameraOffset)
        let orthographic = asset.isPlanar || CADPreferences.cameraProjection == .orthographic
        // Thumbnails are square; a window refits to its own shape on demand.
        let fit = cameraFit(for: asset, orientation: orientation, orthographic: orthographic)

        let target = SCNNode()
        target.name = "CameraTarget"
        target.simdPosition = fit.target
        scene.rootNode.addChildNode(target)

        let camera = SCNNode()
        camera.name = "Camera"
        camera.camera = SCNCamera()
        camera.camera?.fieldOfView = cameraFieldOfView
        camera.camera?.automaticallyAdjustsZRange = true
        camera.simdOrientation = orientation
        camera.simdPosition = fit.target + orientation.act(SIMD3<Float>(0, 0, 1)) * fit.distance
        if orthographic, let cameraGeometry = camera.camera {
            cameraGeometry.usesOrthographicProjection = true
            cameraGeometry.orthographicScale = fit.orthographicScale
        }
        scene.rootNode.addChildNode(camera)
    }
}
