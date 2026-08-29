import AppKit
import SceneKit
import simd

@MainActor
final class InteractiveCADView: SCNView {
    var asset: CADModelAsset? {
        didSet {
            axisProbeLength = asset.map {
                max(Float(CADSceneFactory.fittingRadius(for: $0, around: CADSceneFactory.orbitPivot(for: $0))) * 0.02, 1e-3)
            } ?? 1
        }
    }
    /// Mirrors the scene's display options so picking ignores tangent edges
    /// when they are removed. (Edges hidden by "Shaded without edges" stay
    /// pickable, as in Onshape.)
    private(set) var displayOptions = CADDisplayOptions.default

    func applyDisplayOptions(_ options: CADDisplayOptions) {
        displayOptions = options
        if let scene { CADSceneFactory.apply(options, to: scene) }
    }

    var onHover: ((SmartSelectionTarget?) -> Void)?
    var onSelect: ((SmartSelectionTarget) -> Void)?
    var onCameraOrientationChanged: ((simd_quatf) -> Void)? {
        didSet { publishCameraOrientation() }
    }

    private var trackingAreaReference: NSTrackingArea?
    private var currentHover: SmartSelectionTarget?
    private var faceHighlightNode: SCNNode?
    private var highlightedEdgePoints: [SCNVector3] = []
    private var highlightedVertex: SCNVector3?
    private var measurementPoints: [SCNVector3] = []
    /// Every rotation is about the part's origin (world 0,0,0), wherever the
    /// drag starts — the model swings around its own datum, Onshape-style.
    private let orbitPivot = SIMD3<Float>.zero
    private var cameraAnimation: Timer?
    private var axisProbeLength: Float = 1
    private lazy var vectorOverlay: CADVectorOverlayView = {
        let overlay = CADVectorOverlayView(frame: bounds)
        overlay.autoresizingMask = [.width, .height]
        addSubview(overlay)
        return overlay
    }()

    override var acceptsFirstResponder: Bool { true }

    /// Text placed on the pasteboard by Cmd+C / Edit > Copy; nil when there is
    /// nothing to copy.
    var onCopy: (() -> String?)?

    @objc func copy(_ sender: Any?) {
        guard let text = onCopy?() else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Quick Look hosts the view remotely, where the Edit menu is Finder's;
    /// handle the key equivalent directly so copying works there too.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "c", onCopy?() != nil {
            copy(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    isolated deinit {
        cameraAnimation?.invalidate()
    }

    override func layout() {
        super.layout()
        vectorOverlay.frame = bounds
        refreshVectorOverlay()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaReference { removeTrackingArea(trackingAreaReference) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingAreaReference = area
    }

    // MARK: - Mouse

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        setHover(target(at: point))
    }

    override func mouseExited(with event: NSEvent) {
        setHover(nil)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        // CATIA: middle + left drag rotates, so a left press during a middle drag is not a pick.
        if navigationPreset == .catia, NSEvent.pressedMouseButtons & (1 << 2) != 0 { return }
        let point = convert(event.locationInWindow, from: nil)
        if let target = target(at: point) {
            setHover(target)
            onSelect?(target)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        // With both buttons held AppKit reports left-button drags, so CATIA's
        // middle + left rotate arrives here rather than in otherMouseDragged.
        guard navigationPreset == .catia, NSEvent.pressedMouseButtons & (1 << 2) != 0 else { return }
        orbit(deltaX: event.deltaX, deltaY: event.deltaY)
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func rightMouseDragged(with event: NSEvent) {
        guard navigationPreset == .onshape else { return }
        if event.modifierFlags.contains(.control) {
            pan(deltaX: event.deltaX, deltaY: event.deltaY)
        } else {
            orbit(deltaX: event.deltaX, deltaY: event.deltaY)
        }
    }

    override func otherMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func otherMouseDragged(with event: NSEvent) {
        switch navigationPreset {
        case .onshape:
            pan(deltaX: event.deltaX, deltaY: event.deltaY)
        case .solidWorks:
            if event.modifierFlags.contains(.shift) {
                dragZoom(deltaY: event.deltaY)
            } else if event.modifierFlags.contains(.control) {
                pan(deltaX: event.deltaX, deltaY: event.deltaY)
            } else {
                orbit(deltaX: event.deltaX, deltaY: event.deltaY)
            }
        case .nx, .creo:
            if event.modifierFlags.contains(.shift) {
                pan(deltaX: event.deltaX, deltaY: event.deltaY)
            } else if event.modifierFlags.contains(.control) {
                if navigationPreset == .creo, abs(event.deltaX) > abs(event.deltaY) {
                    // Creo "turn": spin about the axis pointing out of the screen.
                    rotateCamera(yaw: 0, pitch: 0, roll: Float(-event.deltaX * 0.008))
                } else {
                    dragZoom(deltaY: event.deltaY)
                }
            } else {
                orbit(deltaX: event.deltaX, deltaY: event.deltaY)
            }
        case .catia:
            if NSEvent.pressedMouseButtons & 1 != 0 {
                orbit(deltaX: event.deltaX, deltaY: event.deltaY)
            } else if event.modifierFlags.contains(.control) {
                dragZoom(deltaY: event.deltaY)
            } else {
                pan(deltaX: event.deltaX, deltaY: event.deltaY)
            }
        }
    }

    override func scrollWheel(with event: NSEvent) {
        let sensitivity: CGFloat = event.hasPreciseScrollingDeltas ? 0.012 : 0.10
        let point = convert(event.locationInWindow, from: nil)
        zoom(by: exp(-event.scrollingDeltaY * sensitivity), toward: point)
    }

    override func magnify(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        zoom(by: max(0.2, 1 - event.magnification), toward: point)
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        let step: Float
        if event.modifierFlags.contains(.shift) {
            step = .pi / 2
        } else if event.modifierFlags.contains(.control) {
            step = .pi / 36
        } else {
            step = .pi / 12
        }

        if event.modifierFlags.contains([.control, .shift]) {
            switch event.keyCode {
            case 123: pan(deltaX: -30, deltaY: 0)
            case 124: pan(deltaX: 30, deltaY: 0)
            case 125: pan(deltaX: 0, deltaY: 30)
            case 126: pan(deltaX: 0, deltaY: -30)
            default: super.keyDown(with: event)
            }
            return
        }

        if event.modifierFlags.contains(.option) {
            switch event.keyCode {
            case 123: rotateCamera(yaw: 0, pitch: 0, roll: step)
            case 124: rotateCamera(yaw: 0, pitch: 0, roll: -step)
            default: super.keyDown(with: event)
            }
            return
        }

        if isPlanar {
            switch event.keyCode {
            case 123: pan(deltaX: -30, deltaY: 0)
            case 124: pan(deltaX: 30, deltaY: 0)
            case 125: pan(deltaX: 0, deltaY: 30)
            case 126: pan(deltaX: 0, deltaY: -30)
            case _ where event.charactersIgnoringModifiers?.lowercased() == "f": fitView()
            default: super.keyDown(with: event)
            }
            return
        }

        // Arrow keys turn the model the way the arrow points, about the screen axes.
        switch event.keyCode {
        case 123: rotateCamera(yaw: step, pitch: 0, roll: 0)
        case 124: rotateCamera(yaw: -step, pitch: 0, roll: 0)
        case 125: rotateCamera(yaw: 0, pitch: -step, roll: 0)
        case 126: rotateCamera(yaw: 0, pitch: step, roll: 0)
        default:
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "f": fitView()
            case "z": zoom(by: event.modifierFlags.contains(.shift) ? 0.8 : 1.25)
            default: super.keyDown(with: event)
            }
        }
    }

    // MARK: - Public camera API

    func updateMeasurementOverlay(_ result: SmartMeasurementResult?) {
        measurementPoints = result?.points ?? []
        refreshVectorOverlay()
    }

    func setCameraProjection(_ projection: CADCameraProjection) {
        guard let cameraNode, let camera = cameraNode.camera, let targetNode else { return }
        let offset = cameraNode.simdPosition - targetNode.simdPosition
        let distance = max(simd_length(offset), 0.001)
        let fieldOfViewRadians = Float(camera.fieldOfView) * .pi / 180

        switch projection {
        case .orthographic where !camera.usesOrthographicProjection:
            camera.orthographicScale = Double(distance * tan(fieldOfViewRadians * 0.5))
            camera.usesOrthographicProjection = true
        case .perspective where camera.usesOrthographicProjection:
            let matchingDistance = Float(camera.orthographicScale) / tan(fieldOfViewRadians * 0.5)
            cameraNode.simdPosition = targetNode.simdPosition
                + simd_normalize(offset) * max(matchingDistance, 0.001)
            camera.usesOrthographicProjection = false
        default:
            break
        }

        cameraDidMove()
    }

    func snap(to standardView: CADStandardView) {
        snap(to: CADSceneFactory.cameraOrientation(for: isPlanar ? .top : standardView))
    }

    /// Snaps to the view looking from `offset` (a corner of the view cube) at the part.
    func snap(toCameraOffset offset: SIMD3<Float>) {
        guard !isPlanar else { return }
        snap(to: CADSceneFactory.cameraOrientation(offset: offset))
    }

    private func snap(to targetOrientation: simd_quatf) {
        guard let camera = cameraNode, let target = targetNode else { return }
        let radius = max(simd_length(camera.simdPosition - target.simdPosition), 1)
        var orientation = targetOrientation
        // Take the short way round when interpolating.
        if simd_dot(orientation.vector, camera.simdOrientation.vector) < 0 {
            orientation = simd_quatf(vector: -orientation.vector)
        }
        let backward = orientation.act(SIMD3<Float>(0, 0, 1))
        animateCamera(to: target.simdPosition + backward * radius, orientation: orientation, duration: 0.22)
    }

    /// Drives the camera from the main run loop instead of an implicit
    /// SceneKit animation, so every frame the 2D overlay and the view cube are
    /// computed from exactly the transform being rendered.
    private func animateCamera(to position: SIMD3<Float>, orientation: simd_quatf, duration: TimeInterval) {
        cameraAnimation?.invalidate()
        guard let camera = cameraNode else { return }
        let startPosition = camera.simdPosition
        let startOrientation = camera.simdOrientation
        let startTime = CACurrentMediaTime()
        cameraAnimation = Timer.scheduledTimer(withTimeInterval: 1 / 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard let camera = self.cameraNode else {
                    self.cameraAnimation?.invalidate()
                    self.cameraAnimation = nil
                    return
                }
                let t = Float(min(1, (CACurrentMediaTime() - startTime) / duration))
                let eased = t * t * (3 - 2 * t)
                camera.simdPosition = simd_mix(startPosition, position, SIMD3<Float>(repeating: eased))
                camera.simdOrientation = simd_slerp(startOrientation, orientation, eased)
                self.cameraDidMove()
                if t >= 1 {
                    self.cameraAnimation?.invalidate()
                    self.cameraAnimation = nil
                }
            }
        }
    }

    func publishCameraOrientation() {
        guard let camera = cameraNode else { return }
        onCameraOrientationChanged?(camera.simdOrientation)
    }

    // MARK: - Navigation

    private var isPlanar: Bool { asset?.isPlanar ?? false }

    private func orbit(deltaX: CGFloat, deltaY: CGFloat) {
        // 2D drawings never rotate; the orbit gesture pans instead.
        if isPlanar {
            pan(deltaX: deltaX, deltaY: deltaY)
            return
        }
        rotateCamera(yaw: Float(-deltaX * 0.006), pitch: Float(-deltaY * 0.006), roll: 0)
    }

    /// Rotates the camera about the part origin using the *screen* axes: yaw about the screen's vertical axis, pitch about its
    /// horizontal axis and roll about the axis pointing out of the screen. This
    /// is how Onshape, SolidWorks, NX, CATIA and Creo all orbit — there is no
    /// locked "up" direction, so the model can be viewed from any angle.
    private func rotateCamera(yaw: Float, pitch: Float, roll: Float) {
        guard let camera = cameraNode, let target = targetNode, !isPlanar else { return }
        cameraAnimation?.invalidate()
        let pivot = orbitPivot
        let orientation = camera.simdOrientation
        let right = orientation.act(SIMD3<Float>(1, 0, 0))
        let up = orientation.act(SIMD3<Float>(0, 1, 0))
        let forward = orientation.act(SIMD3<Float>(0, 0, -1))

        var rotation = simd_quatf(angle: yaw, axis: up)
        rotation = simd_quatf(angle: pitch, axis: right) * rotation
        if roll != 0 {
            rotation = simd_quatf(angle: roll, axis: forward) * rotation
        }
        rotation = simd_normalize(rotation)

        camera.simdPosition = pivot + rotation.act(camera.simdPosition - pivot)
        target.simdPosition = pivot + rotation.act(target.simdPosition - pivot)
        camera.simdOrientation = simd_normalize(rotation * orientation)
        cameraDidMove()
    }

    private func pan(deltaX: CGFloat, deltaY: CGFloat) {
        guard let camera = cameraNode, let target = targetNode else { return }
        cameraAnimation?.invalidate()
        let scale: Float
        if let cameraGeometry = camera.camera, cameraGeometry.usesOrthographicProjection {
            scale = Float(cameraGeometry.orthographicScale) * 0.0026
        } else {
            let distance = max(simd_length(camera.simdPosition - target.simdPosition), 0.001)
            scale = distance * 0.0018
        }
        let right = camera.simdOrientation.act(SIMD3<Float>(1, 0, 0))
        let up = camera.simdOrientation.act(SIMD3<Float>(0, 1, 0))
        let translation = right * Float(-deltaX) * scale + up * Float(deltaY) * scale
        camera.simdPosition += translation
        target.simdPosition += translation
        cameraDidMove()
    }

    /// Zooms so that the world point under `screenPoint` stays under the
    /// cursor (zoom-to-cursor). Falls back to zooming about the view centre.
    private func zoom(by factor: CGFloat, toward screenPoint: CGPoint? = nil) {
        guard let camera = cameraNode, let target = targetNode else { return }
        cameraAnimation?.invalidate()
        let boundedFactor = Float(max(0.08, min(12, factor)))
        let anchor = screenPoint.map { worldPoint(under: $0) } ?? target.simdPosition

        if let cameraGeometry = camera.camera, cameraGeometry.usesOrthographicProjection {
            cameraGeometry.orthographicScale = max(
                0.000_1,
                cameraGeometry.orthographicScale * Double(boundedFactor)
            )
            let forward = camera.simdOrientation.act(SIMD3<Float>(0, 0, -1))
            let offset = anchor - camera.simdPosition
            let lateral = offset - simd_dot(offset, forward) * forward
            let shift = lateral * (1 - boundedFactor)
            camera.simdPosition += shift
            target.simdPosition += shift
        } else {
            camera.simdPosition = anchor + (camera.simdPosition - anchor) * boundedFactor
            target.simdPosition = anchor + (target.simdPosition - anchor) * boundedFactor
        }
        cameraDidMove()
    }

    private func dragZoom(deltaY: CGFloat) {
        zoom(by: exp(deltaY * 0.012))
    }

    private func fitView() {
        guard let asset, let camera = cameraNode, let target = targetNode else { return }
        let pivot = CADSceneFactory.orbitPivot(for: asset).simdVector
        let fittingRadius = Float(CADSceneFactory.fittingRadius(for: asset, around: SCNVector3(pivot)))
        let backward = camera.simdOrientation.act(SIMD3<Float>(0, 0, 1))
        let distance = fittingRadius * CADSceneFactory.fittingDistanceFactor
        target.simdPosition = pivot
        camera.simdPosition = pivot + backward * distance
        if let cameraGeometry = camera.camera, cameraGeometry.usesOrthographicProjection {
            let fieldOfViewRadians = Float(cameraGeometry.fieldOfView) * .pi / 180
            cameraGeometry.orthographicScale = Double(distance * tan(fieldOfViewRadians * 0.5))
        }
        cameraDidMove()
    }

    private func cameraDidMove() {
        publishCameraOrientation()
        refreshVectorOverlay()
        setNeedsDisplay(bounds)
    }

    /// World point under a screen location: the surface under the cursor if
    /// there is one, otherwise the point on the focal plane through the target.
    private func worldPoint(under screenPoint: CGPoint) -> SIMD3<Float> {
        let hits = hitTest(screenPoint, options: [
            .categoryBitMask: 1,
            .searchMode: SCNHitTestSearchMode.closest.rawValue,
            .ignoreHiddenNodes: false
        ])
        if let hit = hits.first {
            return hit.worldCoordinates.simdVector
        }
        let target = targetNode?.simdPosition ?? .zero
        return projector?.unproject(screenPoint, atDepthOf: target) ?? target
    }

    /// Projects through the camera node's *model* transform rather than
    /// SCNView.projectPoint, which reads the renderer's last-drawn state and so
    /// lags one frame behind while the camera moves.
    private var projector: CADScreenProjector? {
        guard let camera = cameraNode, let cameraGeometry = camera.camera,
              bounds.width > 0, bounds.height > 0 else { return nil }
        return CADScreenProjector(
            view: simd_inverse(camera.simdWorldTransform),
            projection: simd_float4x4(cameraGeometry.projectionTransform(withViewportSize: bounds.size)),
            size: bounds.size
        )
    }

    /// Depth slack (in view-space units) when deciding whether an edge or
    /// vertex is hidden behind the face under the cursor.
    private var depthTolerance: Float {
        guard let camera = cameraNode, let target = targetNode else { return 0.01 }
        return 0.005 * max(simd_length(camera.simdPosition - target.simdPosition), 1)
    }

    private var cameraNode: SCNNode? {
        pointOfView ?? scene?.rootNode.childNode(withName: "Camera", recursively: true)
    }

    private var targetNode: SCNNode? {
        scene?.rootNode.childNode(withName: "CameraTarget", recursively: true)
    }

    private var navigationPreset: CADNavigationPreset {
        CADPreferences.navigationPreset
    }

    // MARK: - Picking and highlighting

    private func target(at screenPoint: CGPoint) -> SmartSelectionTarget? {
        guard let projector else { return nil }
        let hits = hitTest(screenPoint, options: [
            .categoryBitMask: 1,
            .searchMode: SCNHitTestSearchMode.all.rawValue,
            .ignoreHiddenNodes: false,
            .boundingBoxOnly: false
        ])
        let faceHit = hits.first
        let visibleDepth = faceHit.flatMap { projector.project($0.worldCoordinates.simdVector)?.depth }
        if let vertex = nearestVertex(to: screenPoint, noFartherThan: visibleDepth, projector: projector) { return vertex }
        if let edge = nearestEdge(to: screenPoint, noFartherThan: visibleDepth, projector: projector) { return edge }
        guard let faceHit, let asset, !asset.isMesh, asset.triangles.indices.contains(faceHit.faceIndex) else { return nil }
        return .face(index: Int(asset.triangles[faceHit.faceIndex].faceIndex), position: faceHit.worldCoordinates)
    }

    private func setHover(_ target: SmartSelectionTarget?) {
        guard target != currentHover else { return }
        currentHover = target
        applyHighlight(target)
        onHover?(target)
    }

    /// Faces are highlighted with a separate overlay node holding just that
    /// face's triangles; the model geometry itself is never mutated (mutating
    /// its materials races SceneKit's render thread). Edges are highlighted
    /// only in the 2D overlay.
    private func applyHighlight(_ target: SmartSelectionTarget?) {
        faceHighlightNode?.removeFromParentNode()
        faceHighlightNode = nil
        highlightedEdgePoints = []
        highlightedVertex = nil

        switch target {
        case .face(let index, _):
            if let asset,
               let geometry = CADSceneFactory.makeFaceHighlightGeometry(for: asset, faceIndex: index),
               let modelRoot = scene?.rootNode.childNode(withName: CADSceneFactory.modelNodeName, recursively: false) {
                let node = SCNNode(geometry: geometry)
                node.name = "CADFaceHighlight"
                node.categoryBitMask = 8
                modelRoot.addChildNode(node)
                faceHighlightNode = node
            }
        case .edge(let index, _):
            highlightedEdgePoints = edgePoints(index: index)
        case .vertex(_, let position):
            highlightedVertex = position
        case nil:
            break
        }
        refreshVectorOverlay()
        setNeedsDisplay(bounds)
    }

    /// B-Rep vertices snap from further away than edges so they win when the
    /// cursor is near an edge end point.
    private func nearestVertex(
        to screenPoint: CGPoint,
        noFartherThan visibleDepth: Float?,
        projector: CADScreenProjector
    ) -> SmartSelectionTarget? {
        guard let asset else { return nil }
        let tolerance = depthTolerance
        var bestDistance: CGFloat = 9
        var best: SmartSelectionTarget?
        for (index, vertex) in asset.topologicalVertices.enumerated() {
            guard let projected = projector.project(vertex.simdVector) else { continue }
            if let visibleDepth, projected.depth > visibleDepth + tolerance { continue }
            let distance = hypot(projected.point.x - screenPoint.x, projected.point.y - screenPoint.y)
            if distance < bestDistance {
                bestDistance = distance
                best = .vertex(index: index, position: vertex)
            }
        }
        return best
    }

    private func nearestEdge(
        to screenPoint: CGPoint,
        noFartherThan visibleDepth: Float?,
        projector: CADScreenProjector
    ) -> SmartSelectionTarget? {
        guard let asset else { return nil }
        let tolerance = depthTolerance
        var bestDistance = CGFloat.greatestFiniteMagnitude
        var bestEdge: Int?
        var bestPoint = SCNVector3Zero
        let points = asset.polylineSimd

        let skipsTangent = displayOptions.tangentEdges == .removed
        for (edgeIndex, edge) in asset.edges.enumerated() {
            if skipsTangent, edge.isTangent != 0 { continue }
            let first = Int(edge.firstPoint)
            let count = Int(edge.pointCount)
            guard count > 1, first + count <= points.count else { continue }
            for offset in 0..<(count - 1) {
                let worldA = points[first + offset]
                let worldB = points[first + offset + 1]
                guard let projectedA = projector.project(worldA),
                      let projectedB = projector.project(worldB) else { continue }
                let result = distance(from: screenPoint, toSegmentFrom: projectedA.point, to: projectedB.point)
                let projectedDepth = projectedA.depth + (projectedB.depth - projectedA.depth) * Float(result.fraction)
                if let visibleDepth, projectedDepth > visibleDepth + tolerance { continue }
                if result.distance < bestDistance {
                    bestDistance = result.distance
                    bestEdge = edgeIndex
                    bestPoint = SCNVector3(simd_mix(worldA, worldB, SIMD3<Float>(repeating: Float(result.fraction))))
                }
            }
        }
        guard bestDistance <= 4, let bestEdge else { return nil }
        return .edge(index: bestEdge, position: bestPoint)
    }

    private func distance(from point: CGPoint, toSegmentFrom a: CGPoint, to b: CGPoint) -> (distance: CGFloat, fraction: CGFloat) {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return (hypot(point.x - a.x, point.y - a.y), 0) }
        let fraction = max(0, min(1, ((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared))
        let closest = CGPoint(x: a.x + fraction * dx, y: a.y + fraction * dy)
        return (hypot(point.x - closest.x, point.y - closest.y), fraction)
    }

    private func edgePoints(index: Int) -> [SCNVector3] {
        guard let asset, asset.edges.indices.contains(index) else { return [] }
        let edge = asset.edges[index]
        let first = Int(edge.firstPoint)
        let count = Int(edge.pointCount)
        guard count > 1, first + count <= asset.polylinePoints.count else { return [] }
        return asset.polylinePoints[first..<(first + count)].map(\.sceneVector)
    }

    private func refreshVectorOverlay() {
        guard let projector else {
            vectorOverlay.selectionPoints = []
            vectorOverlay.measurementPoints = []
            vectorOverlay.vertexPoint = nil
            vectorOverlay.axes = []
            vectorOverlay.originPoint = nil
            return
        }
        vectorOverlay.selectionPoints = highlightedEdgePoints.compactMap { projector.project($0.simdVector)?.point }
        vectorOverlay.measurementPoints = measurementPoints.compactMap { projector.project($0.simdVector)?.point }
        vectorOverlay.vertexPoint = highlightedVertex.flatMap { projector.project($0.simdVector)?.point }
        updateAxisOverlay(projector)
    }

    /// Draws the model origin and X/Y/Z axes as a screen-space triad: a fixed
    /// on-screen length, foreshortened by how much each axis points at the camera.
    private func updateAxisOverlay(_ projector: CADScreenProjector) {
        guard let camera = cameraNode,
              let origin = projector.project(.zero),
              let reference = projector.project(camera.simdOrientation.act(SIMD3<Float>(1, 0, 0)) * axisProbeLength)
        else {
            vectorOverlay.axes = []
            vectorOverlay.originPoint = nil
            return
        }
        let referenceLength = hypot(reference.point.x - origin.point.x, reference.point.y - origin.point.y)
        let scale = 56 / max(referenceLength, 0.001)
        let axes: [(String, SIMD3<Float>, NSColor)] = [
            ("X", SIMD3<Float>(1, 0, 0), .systemRed),
            ("Y", SIMD3<Float>(0, 1, 0), .systemGreen),
            ("Z", SIMD3<Float>(0, 0, 1), .systemBlue)
        ]
        vectorOverlay.axes = axes.compactMap { label, direction, color in
            guard let tip = projector.project(direction * axisProbeLength) else { return nil }
            let end = CGPoint(
                x: origin.point.x + (tip.point.x - origin.point.x) * scale,
                y: origin.point.y + (tip.point.y - origin.point.y) * scale
            )
            return CADOverlayAxis(start: origin.point, end: end, color: color, label: label)
        }
        vectorOverlay.originPoint = origin.point
    }

}

@MainActor
private final class CADVectorOverlayView: NSView {
    var selectionPoints: [CGPoint] = [] { didSet { needsDisplay = true } }
    var measurementPoints: [CGPoint] = [] { didSet { needsDisplay = true } }
    var vertexPoint: CGPoint? { didSet { needsDisplay = true } }
    var axes: [CADOverlayAxis] = [] { didSet { needsDisplay = true } }
    var originPoint: CGPoint? { didSet { needsDisplay = true } }

    private let axisLabelFont = NSFont(name: "Helvetica-Bold", size: 12) ?? .boldSystemFont(ofSize: 12)

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawAxes()
        NSColor.systemOrange.setStroke()
        NSColor.systemOrange.setFill()

        stroke(points: measurementPoints, lineWidth: 2.5)
        for point in measurementPoints.prefix(2) {
            NSBezierPath(ovalIn: NSRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)).fill()
        }
        stroke(points: selectionPoints, lineWidth: 4)

        if let vertexPoint {
            NSBezierPath(ovalIn: NSRect(x: vertexPoint.x - 4, y: vertexPoint.y - 4, width: 8, height: 8)).fill()
        }
    }

    private func drawAxes() {
        for axis in axes {
            axis.color.setStroke()
            let path = NSBezierPath()
            path.move(to: axis.start)
            path.line(to: axis.end)
            path.lineWidth = 2
            path.lineCapStyle = .round
            path.stroke()

            let dx = axis.end.x - axis.start.x
            let dy = axis.end.y - axis.start.y
            let length = max(hypot(dx, dy), 0.001)
            let labelCenter = CGPoint(x: axis.end.x + dx / length * 10, y: axis.end.y + dy / length * 10)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: axisLabelFont,
                .foregroundColor: axis.color,
                .shadow: {
                    let shadow = NSShadow()
                    shadow.shadowColor = NSColor.black.withAlphaComponent(0.6)
                    shadow.shadowBlurRadius = 2
                    return shadow
                }()
            ]
            let size = axis.label.size(withAttributes: attributes)
            axis.label.draw(
                at: CGPoint(x: labelCenter.x - size.width / 2, y: labelCenter.y - size.height / 2),
                withAttributes: attributes
            )
        }
        if let originPoint {
            NSColor.white.setFill()
            NSBezierPath(ovalIn: NSRect(x: originPoint.x - 3, y: originPoint.y - 3, width: 6, height: 6)).fill()
        }
    }

    private func stroke(points: [CGPoint], lineWidth: CGFloat) {
        guard points.count > 1 else { return }
        let path = NSBezierPath()
        path.move(to: points[0])
        for point in points.dropFirst() { path.line(to: point) }
        path.lineWidth = lineWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()
    }
}

struct CADOverlayAxis {
    let start: CGPoint
    let end: CGPoint
    let color: NSColor
    let label: String
}

/// Projects world points to AppKit view coordinates using the camera's
/// current (not last-rendered) transform.
struct CADScreenProjector {
    let view: simd_float4x4
    let projection: simd_float4x4
    let size: CGSize

    /// Screen point (origin bottom-left) and linear view-space depth, or nil
    /// when the point is behind the camera.
    func project(_ world: SIMD3<Float>) -> (point: CGPoint, depth: Float)? {
        let viewPosition = view * SIMD4<Float>(world, 1)
        let depth = -viewPosition.z
        guard depth > 0 else { return nil }
        let clip = projection * viewPosition
        guard clip.w > 0 else { return nil }
        let x = CGFloat((clip.x / clip.w + 1) * 0.5) * size.width
        let y = CGFloat((clip.y / clip.w + 1) * 0.5) * size.height
        return (CGPoint(x: x, y: y), depth)
    }

    func unproject(_ screen: CGPoint, atDepthOf world: SIMD3<Float>) -> SIMD3<Float> {
        let viewProjection = projection * view
        let reference = viewProjection * SIMD4<Float>(world, 1)
        let ndc = SIMD4<Float>(
            Float(screen.x / size.width) * 2 - 1,
            Float(screen.y / size.height) * 2 - 1,
            reference.z / reference.w,
            1
        )
        let result = simd_inverse(viewProjection) * ndc
        return SIMD3<Float>(result.x, result.y, result.z) / result.w
    }
}

private extension SmartSelectionTarget {
    var position: SCNVector3 {
        switch self {
        case .vertex(_, let position), .edge(_, let position), .face(_, let position): position
        }
    }
}

extension SCNVector3 {
    var simdVector: SIMD3<Float> { SIMD3<Float>(Float(x), Float(y), Float(z)) }
}
