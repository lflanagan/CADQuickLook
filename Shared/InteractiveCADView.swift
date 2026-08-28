import AppKit
import SceneKit
import simd

@MainActor
final class InteractiveCADView: SCNView {
    var asset: CADModelAsset?
    var onHover: ((SmartSelectionTarget?) -> Void)?
    var onSelect: ((SmartSelectionTarget) -> Void)?
    var onViewDirectionChanged: ((SCNVector3) -> Void)? {
        didSet { publishViewDirection() }
    }

    private var trackingAreaReference: NSTrackingArea?
    private var currentHover: SmartSelectionTarget?
    private var highlightedFace: Int?
    private var highlightedEdge: Int?
    private var highlightedEdgePoints: [SCNVector3] = []
    private var measurementPoints: [SCNVector3] = []
    private var surfaceBaseMaterial: SCNMaterial?
    private var edgeBaseMaterial: SCNMaterial?
    private var onshapeOrbitPivot: SCNVector3?
    private lazy var vectorOverlay: CADVectorOverlayView = {
        let overlay = CADVectorOverlayView(frame: bounds)
        overlay.autoresizingMask = [.width, .height]
        addSubview(overlay)
        return overlay
    }()

    override var acceptsFirstResponder: Bool { true }

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

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        setHover(target(at: point))
    }

    override func mouseExited(with event: NSEvent) {
        setHover(nil)
    }

    override func mouseDown(with event: NSEvent) {
        if navigationPreset == .catia, NSEvent.pressedMouseButtons & (1 << 2) != 0 { return }
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        if let target = target(at: point) {
            setHover(target)
            onSelect?(target)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard navigationPreset == .onshape,
              !event.modifierFlags.contains(.control) else {
            onshapeOrbitPivot = nil
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        onshapeOrbitPivot = target(at: point)?.position ?? asset.map(CADSceneFactory.orbitPivot)
    }

    override func rightMouseUp(with event: NSEvent) {
        onshapeOrbitPivot = nil
    }

    override func rightMouseDragged(with event: NSEvent) {
        guard navigationPreset == .onshape else { return }
        if event.modifierFlags.contains(.control) {
            pan(deltaX: event.deltaX, deltaY: event.deltaY)
        } else {
            onshapeOrbit(deltaX: event.deltaX, deltaY: event.deltaY)
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
                    orbit(yaw: -event.deltaX * 0.008, pitch: 0)
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
        zoom(by: exp(-event.scrollingDeltaY * sensitivity))
    }

    override func magnify(with event: NSEvent) {
        zoom(by: max(0.2, 1 - event.magnification))
    }

    override func keyDown(with event: NSEvent) {
        let step: CGFloat
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

        switch event.keyCode {
        case 123: orbit(yaw: -step, pitch: 0)
        case 124: orbit(yaw: step, pitch: 0)
        case 125: orbit(yaw: 0, pitch: -step)
        case 126: orbit(yaw: 0, pitch: step)
        default:
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "f": fitView()
            case "z": zoom(by: event.modifierFlags.contains(.shift) ? 0.8 : 1.25)
            default: super.keyDown(with: event)
            }
        }
    }

    func updateMeasurementOverlay(_ result: SmartMeasurementResult?) {
        measurementPoints = result?.points ?? []
        refreshVectorOverlay()
    }

    func setCameraProjection(_ projection: CADCameraProjection) {
        guard let cameraNode, let camera = cameraNode.camera, let targetNode else { return }
        let offset = subtract(cameraNode.position, targetNode.position)
        let distance = max(length(offset), 0.001)
        let fieldOfViewRadians = CGFloat(camera.fieldOfView) * .pi / 180

        switch projection {
        case .orthographic where !camera.usesOrthographicProjection:
            camera.orthographicScale = 2 * distance * tan(fieldOfViewRadians * 0.5)
            camera.usesOrthographicProjection = true
        case .perspective where camera.usesOrthographicProjection:
            let matchingDistance = CGFloat(camera.orthographicScale) / (2 * tan(fieldOfViewRadians * 0.5))
            cameraNode.position = add(
                targetNode.position,
                multiply(normalized(offset), max(matchingDistance, 0.001))
            )
            camera.usesOrthographicProjection = false
        default:
            break
        }

        refreshVectorOverlay()
        setNeedsDisplay(bounds)
    }

    private func target(at screenPoint: CGPoint) -> SmartSelectionTarget? {
        let hits = hitTest(screenPoint, options: [
            .categoryBitMask: 1,
            .searchMode: SCNHitTestSearchMode.all.rawValue,
            .ignoreHiddenNodes: false,
            .boundingBoxOnly: false
        ])
        let faceHit = hits.first
        let visibleDepth = faceHit.map { projectPoint($0.worldCoordinates).z }
        if let edge = nearestEdge(to: screenPoint, noFartherThan: visibleDepth) { return edge }
        guard let faceHit else { return nil }
        return .face(index: faceHit.geometryIndex, position: faceHit.worldCoordinates)
    }

    private func setHover(_ target: SmartSelectionTarget?) {
        guard target != currentHover else { return }
        currentHover = target
        applyHighlight(target)
        onHover?(target)
    }

    private func orbit(deltaX: CGFloat, deltaY: CGFloat) {
        orbit(yaw: -deltaX * 0.008, pitch: -deltaY * 0.008)
    }

    private func onshapeOrbit(deltaX: CGFloat, deltaY: CGFloat) {
        guard let camera = cameraNode,
              let target = targetNode,
              let root = scene?.rootNode else { return }
        let pivot = onshapeOrbitPivot ?? asset.map(CADSceneFactory.orbitPivot) ?? target.position
        let worldUp = normalized(camera.presentation.convertVector(SCNVector3(0, 1, 0), to: root))
        let worldRight = normalized(camera.presentation.convertVector(SCNVector3(1, 0, 0), to: root))

        let yaw = simd_quatf(angle: Float(-deltaX * 0.006), axis: worldUp.simdVector)
        let pitchAxis = yaw.act(worldRight.simdVector)
        let pitch = simd_quatf(angle: Float(-deltaY * 0.006), axis: pitchAxis)
        let rotation = pitch * yaw

        camera.position = rotated(camera.position, around: pivot, by: rotation)
        target.position = rotated(target.position, around: pivot, by: rotation)
        publishViewDirection()
        refreshVectorOverlay()
        setNeedsDisplay(bounds)
    }

    private func orbit(yaw yawDelta: CGFloat, pitch pitchDelta: CGFloat) {
        guard let camera = cameraNode, let target = targetNode else { return }
        let offset = subtract(camera.position, target.position)
        let radius = max(length(offset), 0.001)
        var yaw = atan2(offset.x, offset.z)
        var pitch = asin(max(-1, min(1, offset.y / radius)))
        yaw += yawDelta
        pitch = max(-(.pi / 2 - 0.02), min(.pi / 2 - 0.02, pitch + pitchDelta))
        let horizontal = radius * cos(pitch)
        camera.position = add(target.position, SCNVector3(
            horizontal * sin(yaw),
            radius * sin(pitch),
            horizontal * cos(yaw)
        ))
        publishViewDirection()
        refreshVectorOverlay()
        setNeedsDisplay(bounds)
    }

    private func pan(deltaX: CGFloat, deltaY: CGFloat) {
        guard let camera = cameraNode, let target = targetNode, let root = scene?.rootNode else { return }
        let scale: CGFloat
        if let cameraGeometry = camera.camera, cameraGeometry.usesOrthographicProjection {
            scale = CGFloat(cameraGeometry.orthographicScale) * 0.0026
        } else {
            let distance = max(length(subtract(camera.position, target.position)), 0.001)
            scale = distance * 0.0018
        }
        let right = camera.presentation.convertVector(SCNVector3(1, 0, 0), to: root)
        let up = camera.presentation.convertVector(SCNVector3(0, 1, 0), to: root)
        let translation = add(multiply(right, -deltaX * scale), multiply(up, deltaY * scale))
        camera.position = add(camera.position, translation)
        target.position = add(target.position, translation)
        refreshVectorOverlay()
        setNeedsDisplay(bounds)
    }

    private func zoom(by factor: CGFloat) {
        guard let camera = cameraNode, let target = targetNode else { return }
        let boundedFactor = max(0.08, min(12, factor))
        if let cameraGeometry = camera.camera, cameraGeometry.usesOrthographicProjection {
            cameraGeometry.orthographicScale = max(
                0.000_1,
                CGFloat(cameraGeometry.orthographicScale) * boundedFactor
            )
            refreshVectorOverlay()
            setNeedsDisplay(bounds)
            return
        }
        let offset = subtract(camera.position, target.position)
        camera.position = add(target.position, multiply(offset, boundedFactor))
        refreshVectorOverlay()
        setNeedsDisplay(bounds)
    }

    private func dragZoom(deltaY: CGFloat) {
        zoom(by: exp(deltaY * 0.012))
    }

    private func fitView() {
        guard let asset, let camera = cameraNode, let target = targetNode else { return }
        let pivot = CADSceneFactory.orbitPivot(for: asset)
        let fittingRadius = CADSceneFactory.fittingRadius(for: asset, around: pivot)
        let currentDirection = normalized(subtract(camera.position, target.position))
        target.position = pivot
        camera.position = add(pivot, multiply(currentDirection, fittingRadius * 3.4))
        if let cameraGeometry = camera.camera, cameraGeometry.usesOrthographicProjection {
            let fieldOfViewRadians = CGFloat(cameraGeometry.fieldOfView) * .pi / 180
            cameraGeometry.orthographicScale = 2 * fittingRadius * 3.4 * tan(fieldOfViewRadians * 0.5)
        }
        publishViewDirection()
        refreshVectorOverlay()
        setNeedsDisplay(bounds)
    }

    func snap(to standardView: CADStandardView) {
        guard let camera = cameraNode, let target = targetNode else { return }
        let radius = max(length(subtract(camera.position, target.position)), 1)
        let direction: SCNVector3
        switch standardView {
        case .isometric: direction = normalized(SCNVector3(1, -1, 1))
        case .top: direction = SCNVector3(0, 0.001, 1)
        case .bottom: direction = SCNVector3(0, 0.001, -1)
        case .front: direction = SCNVector3(0, -1, 0.001)
        case .back: direction = SCNVector3(0, 1, 0.001)
        case .left: direction = SCNVector3(-1, 0, 0)
        case .right: direction = SCNVector3(1, 0, 0)
        }
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.22
        SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        camera.position = add(target.position, multiply(direction, radius))
        SCNTransaction.commit()
        publishViewDirection()
        refreshVectorOverlay()
        setNeedsDisplay(bounds)
    }

    func publishViewDirection() {
        guard let camera = cameraNode, let target = targetNode else { return }
        onViewDirectionChanged?(normalized(subtract(camera.position, target.position)))
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

    private func add(_ a: SCNVector3, _ b: SCNVector3) -> SCNVector3 {
        SCNVector3(a.x + b.x, a.y + b.y, a.z + b.z)
    }

    private func subtract(_ a: SCNVector3, _ b: SCNVector3) -> SCNVector3 {
        SCNVector3(a.x - b.x, a.y - b.y, a.z - b.z)
    }

    private func multiply(_ vector: SCNVector3, _ scalar: CGFloat) -> SCNVector3 {
        SCNVector3(vector.x * scalar, vector.y * scalar, vector.z * scalar)
    }

    private func length(_ vector: SCNVector3) -> CGFloat {
        sqrt(vector.x * vector.x + vector.y * vector.y + vector.z * vector.z)
    }

    private func normalized(_ vector: SCNVector3) -> SCNVector3 {
        let magnitude = max(length(vector), 0.0001)
        return multiply(vector, 1 / magnitude)
    }

    private func rotated(_ point: SCNVector3, around pivot: SCNVector3, by rotation: simd_quatf) -> SCNVector3 {
        let offset = subtract(point, pivot).simdVector
        return add(pivot, SCNVector3(rotation.act(offset)))
    }

    private func applyHighlight(_ target: SmartSelectionTarget?) {
        if let index = highlightedFace,
           let geometry = scene?.rootNode.childNode(withName: CADSceneFactory.surfaceNodeName, recursively: true)?.geometry,
           geometry.materials.indices.contains(index), let surfaceBaseMaterial {
            geometry.materials[index] = surfaceBaseMaterial
        }
        if let index = highlightedEdge,
           let geometry = scene?.rootNode.childNode(withName: CADSceneFactory.edgeNodeName, recursively: true)?.geometry,
           geometry.materials.indices.contains(index), let edgeBaseMaterial {
            geometry.materials[index] = edgeBaseMaterial
        }
        highlightedEdgePoints = []
        highlightedFace = nil
        highlightedEdge = nil

        switch target {
        case .face(let index, _):
            if let geometry = scene?.rootNode.childNode(withName: CADSceneFactory.surfaceNodeName, recursively: true)?.geometry,
               geometry.materials.indices.contains(index) {
                surfaceBaseMaterial = surfaceBaseMaterial ?? geometry.materials[index]
                geometry.materials[index] = surfaceHighlightMaterial()
                highlightedFace = index
            }
        case .edge(let index, _):
            if let geometry = scene?.rootNode.childNode(withName: CADSceneFactory.edgeNodeName, recursively: true)?.geometry,
               geometry.materials.indices.contains(index) {
                edgeBaseMaterial = edgeBaseMaterial ?? geometry.materials[index]
                geometry.materials[index] = highlightMaterial()
                highlightedEdgePoints = edgePoints(index: index)
                highlightedEdge = index
            }
        case nil:
            break
        }
        refreshVectorOverlay()
        setNeedsDisplay(bounds)
    }

    private func nearestEdge(to screenPoint: CGPoint, noFartherThan visibleDepth: CGFloat?) -> SmartSelectionTarget? {
        guard let asset else { return nil }
        var bestDistance = CGFloat.greatestFiniteMagnitude
        var bestEdge: Int?
        var bestPoint = SCNVector3Zero

        for (edgeIndex, edge) in asset.edges.enumerated() {
            let first = Int(edge.firstPoint)
            let count = Int(edge.pointCount)
            guard count > 1, first + count <= asset.polylinePoints.count else { continue }
            for offset in 0..<(count - 1) {
                let worldA = asset.polylinePoints[first + offset].sceneVector
                let worldB = asset.polylinePoints[first + offset + 1].sceneVector
                let projectedA = projectPoint(worldA)
                let projectedB = projectPoint(worldB)
                guard projectedA.z >= 0, projectedA.z <= 1, projectedB.z >= 0, projectedB.z <= 1 else { continue }
                let result = distance(
                    from: screenPoint,
                    toSegmentFrom: CGPoint(x: projectedA.x, y: projectedA.y),
                    to: CGPoint(x: projectedB.x, y: projectedB.y)
                )
                let projectedDepth = projectedA.z + (projectedB.z - projectedA.z) * result.fraction
                if let visibleDepth, projectedDepth > visibleDepth + 0.004 { continue }
                if result.distance < bestDistance {
                    bestDistance = result.distance
                    bestEdge = edgeIndex
                    let fraction = result.fraction
                    bestPoint = SCNVector3(
                        worldA.x + (worldB.x - worldA.x) * fraction,
                        worldA.y + (worldB.y - worldA.y) * fraction,
                        worldA.z + (worldB.z - worldA.z) * fraction
                    )
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
        vectorOverlay.selectionPoints = highlightedEdgePoints.map {
            let point = projectPoint($0)
            return CGPoint(x: CGFloat(point.x), y: CGFloat(point.y))
        }
        vectorOverlay.measurementPoints = measurementPoints.map {
            let point = projectPoint($0)
            return CGPoint(x: CGFloat(point.x), y: CGFloat(point.y))
        }
    }

    private func highlightMaterial() -> SCNMaterial {
        let material = SCNMaterial()
        material.diffuse.contents = NSColor.systemOrange
        material.emission.contents = NSColor.systemOrange
        material.lightingModel = .constant
        return material
    }

    private func surfaceHighlightMaterial() -> SCNMaterial {
        let material = SCNMaterial()
        material.diffuse.contents = NSColor.systemOrange
        material.emission.contents = NSColor.systemOrange.withAlphaComponent(0.35)
        material.metalness.contents = 0.15
        material.roughness.contents = 0.28
        material.isDoubleSided = true
        return material
    }

}

@MainActor
private final class CADVectorOverlayView: NSView {
    var selectionPoints: [CGPoint] = [] { didSet { needsDisplay = true } }
    var measurementPoints: [CGPoint] = [] { didSet { needsDisplay = true } }

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.systemOrange.setStroke()
        NSColor.systemOrange.setFill()

        stroke(points: measurementPoints, lineWidth: 2.5)
        for point in measurementPoints.prefix(2) {
            NSBezierPath(ovalIn: NSRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)).fill()
        }
        stroke(points: selectionPoints, lineWidth: 5)
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

private extension SmartSelectionTarget {
    var position: SCNVector3 {
        switch self {
        case .edge(_, let position), .face(_, let position): position
        }
    }
}

private extension SCNVector3 {
    var simdVector: SIMD3<Float> { SIMD3<Float>(Float(x), Float(y), Float(z)) }
}
