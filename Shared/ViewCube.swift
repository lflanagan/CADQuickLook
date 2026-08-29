import AppKit
import SceneKit
import simd

enum CADStandardView: String, CaseIterable, Identifiable {
    case isometric, top, bottom, front, back, left, right
    var id: Self { self }
    var title: String { rawValue.capitalized }
}

@MainActor
final class CADOrientationWidgetView: NSView, NSMenuDelegate {
    var onSnap: ((CADStandardView) -> Void)? {
        didSet { cubeView.onSnap = onSnap }
    }
    /// Called with the cube-corner direction (each component ±1) to look from.
    var onSnapCorner: ((SIMD3<Float>) -> Void)? {
        didSet { cubeView.onSnapCorner = onSnapCorner }
    }
    var onProjectionChange: ((CADCameraProjection) -> Void)?
    /// 2D drawings have a fixed top-down view, so the cube is hidden.
    var isPlanar = false {
        didSet { cubeView.isHidden = isPlanar }
    }

    var cameraOrientation = CADSceneFactory.cameraOrientation(offset: CADSceneFactory.defaultCameraOffset) {
        didSet { cubeView.cameraOrientation = cameraOrientation }
    }

    private let cubeView = CADOrientationCubeSceneView(frame: .zero, options: nil)
    private let viewsButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private var shadingItem: NSMenuItem?
    private var hiddenEdgeItem: NSMenuItem?
    private var tangentEdgeItem: NSMenuItem?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        cubeView.translatesAutoresizingMaskIntoConstraints = false
        viewsButton.translatesAutoresizingMaskIntoConstraints = false
        cubeView.wantsLayer = true
        cubeView.layer?.isOpaque = false
        cubeView.layer?.backgroundColor = NSColor.clear.cgColor
        cubeView.layer?.zPosition = 0
        addSubview(cubeView)
        addSubview(viewsButton)

        configureViewsMenu()
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 158),
            heightAnchor.constraint(equalToConstant: 184),
            cubeView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            cubeView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            cubeView.topAnchor.constraint(equalTo: topAnchor, constant: 30),
            cubeView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            viewsButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            viewsButton.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            viewsButton.widthAnchor.constraint(equalToConstant: 32),
            viewsButton.heightAnchor.constraint(equalToConstant: 24)
        ])
        cubeView.cameraOrientation = cameraOrientation
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize { NSSize(width: 158, height: 184) }

    private func configureViewsMenu() {
        viewsButton.title = ""
        viewsButton.imagePosition = .imageOnly
        viewsButton.bezelStyle = .inline
        viewsButton.controlSize = .small
        viewsButton.isBordered = false
        viewsButton.contentTintColor = .labelColor
        viewsButton.focusRingType = .none
        viewsButton.toolTip = "Views and settings"
        viewsButton.setAccessibilityLabel("Views and settings")
        viewsButton.target = self
        viewsButton.action = #selector(selectMenuItem(_:))
        (viewsButton.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu(title: "Views and Settings")
        menu.delegate = self
        // A pull-down uses its first item as the control's visible content.
        // Keep that item empty so the compact control is only the native arrow.
        let displayItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        displayItem.image = NSImage(
            systemSymbolName: "chevron.down",
            accessibilityDescription: "Views and settings"
        )
        menu.addItem(displayItem)
        menu.addItem(.sectionHeader(title: "Standard Views"))
        for view in CADStandardView.allCases {
            let item = NSMenuItem(title: view.title, action: #selector(selectStandardView(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = "view:\(view.rawValue)"
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Display"))
        shadingItem = addDisplaySubmenu(to: menu, prefix: "shading", modes: Array(CADShadingMode.allCases))
        hiddenEdgeItem = addDisplaySubmenu(to: menu, prefix: "hidden", modes: Array(CADHiddenEdgeMode.allCases))
        tangentEdgeItem = addDisplaySubmenu(to: menu, prefix: "tangent", modes: Array(CADTangentEdgeMode.allCases))
        refreshDisplayItems()
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Camera Projection"))
        let selectedProjection = CADPreferences.cameraProjection
        for projection in CADCameraProjection.allCases {
            let item = NSMenuItem(title: projection.title, action: #selector(selectCameraProjection(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = "projection:\(projection.rawValue)"
            item.state = projection == selectedProjection ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Units"))
        let selectedUnit = CADPreferences.lengthUnit
        for unit in CADLengthUnit.allCases {
            let item = NSMenuItem(title: "\(unit.title) (\(unit.symbol))", action: #selector(selectLengthUnit(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = "unit:\(unit.rawValue)"
            item.state = unit == selectedUnit ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Navigation Controls"))
        let selectedPreset = CADPreferences.navigationPreset
        for preset in CADNavigationPreset.allCases {
            let item = NSMenuItem(title: preset.title, action: #selector(selectNavigationPreset(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = "preset:\(preset.rawValue)"
            item.state = preset == selectedPreset ? .on : .off
            menu.addItem(item)
        }
        viewsButton.menu = menu
        viewsButton.selectItem(at: 0)
        viewsButton.image = displayItem.image
    }

    /// A parent item that reads as the current choice (checked, like Onshape's
    /// view menu) with the alternatives in a native submenu.
    private func addDisplaySubmenu<Mode: CADDisplayMode>(to menu: NSMenu, prefix: String, modes: [Mode]) -> NSMenuItem {
        let parent = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "")
        for mode in modes {
            let item = NSMenuItem(title: mode.title, action: #selector(selectDisplayOption(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = "\(prefix):\(mode.rawValue)"
            submenu.addItem(item)
        }
        parent.submenu = submenu
        menu.addItem(parent)
        return parent
    }

    private func refreshDisplayItems() {
        let options = CADPreferences.displayOptions
        refresh(shadingItem, selected: options.shading)
        refresh(hiddenEdgeItem, selected: options.hiddenEdges)
        refresh(tangentEdgeItem, selected: options.tangentEdges)
    }

    private func refresh<Mode: CADDisplayMode>(_ parent: NSMenuItem?, selected: Mode) {
        guard let parent else { return }
        parent.title = selected.title
        parent.state = .on
        for item in parent.submenu?.items ?? [] {
            let isSelected = (item.representedObject as? String)?.hasSuffix(":\(selected.rawValue)") == true
            item.state = isSelected ? .on : .off
        }
    }

    /// Applies a "shading:", "hidden:" or "tangent:" menu identifier; false for any other.
    @discardableResult
    private func applyDisplayIdentifier(_ identifier: String) -> Bool {
        let parts = identifier.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return false }
        var options = CADPreferences.displayOptions
        switch parts[0] {
        case "shading":
            guard let mode = CADShadingMode(rawValue: parts[1]) else { return false }
            options.shading = mode
        case "hidden":
            guard let mode = CADHiddenEdgeMode(rawValue: parts[1]) else { return false }
            options.hiddenEdges = mode
        case "tangent":
            guard let mode = CADTangentEdgeMode(rawValue: parts[1]) else { return false }
            options.tangentEdges = mode
        default:
            return false
        }
        CADPreferences.setDisplayOptions(options)
        refreshDisplayItems()
        return true
    }

    @objc private func selectDisplayOption(_ sender: NSMenuItem) {
        guard let identifier = sender.representedObject as? String else { return }
        applyDisplayIdentifier(identifier)
        viewsButton.selectItem(at: 0)
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshDisplayItems()
        let selectedPreset = CADPreferences.navigationPreset
        let selectedProjection = CADPreferences.cameraProjection
        let selectedUnit = CADPreferences.lengthUnit
        onProjectionChange?(selectedProjection)
        for item in menu.items {
            guard let identifier = item.representedObject as? String,
                  let rawValue = identifier.split(separator: ":", maxSplits: 1).last.map(String.init) else { continue }
            if identifier.hasPrefix("preset:"),
               let preset = CADNavigationPreset(rawValue: rawValue) {
                item.state = preset == selectedPreset ? .on : .off
            } else if identifier.hasPrefix("projection:"),
                      let projection = CADCameraProjection(rawValue: rawValue) {
                item.state = projection == selectedProjection ? .on : .off
            } else if identifier.hasPrefix("unit:"),
                      let unit = CADLengthUnit(rawValue: rawValue) {
                item.state = unit == selectedUnit ? .on : .off
            }
        }
    }

    @objc private func selectMenuItem(_ sender: NSPopUpButton) {
        guard let identifier = sender.selectedItem?.representedObject as? String else { return }
        if applyDisplayIdentifier(identifier) {
            // Display options are handled above.
        } else if identifier.hasPrefix("view:"),
           let rawValue = identifier.split(separator: ":", maxSplits: 1).last.map(String.init),
           let view = CADStandardView(rawValue: rawValue) {
            onSnap?(view)
        } else if identifier.hasPrefix("preset:"),
                  let rawValue = identifier.split(separator: ":", maxSplits: 1).last.map(String.init),
                  let preset = CADNavigationPreset(rawValue: rawValue) {
            CADPreferences.setNavigationPreset(preset)
        } else if identifier.hasPrefix("projection:"),
                  let rawValue = identifier.split(separator: ":", maxSplits: 1).last.map(String.init),
                  let projection = CADCameraProjection(rawValue: rawValue) {
            CADPreferences.setCameraProjection(projection)
            onProjectionChange?(projection)
        } else if identifier.hasPrefix("unit:"),
                  let rawValue = identifier.split(separator: ":", maxSplits: 1).last.map(String.init),
                  let unit = CADLengthUnit(rawValue: rawValue) {
            CADPreferences.setLengthUnit(unit)
        }
        sender.selectItem(at: 0)
    }

    @objc private func selectStandardView(_ sender: NSMenuItem) {
        guard let identifier = sender.representedObject as? String,
              let rawValue = identifier.split(separator: ":", maxSplits: 1).last.map(String.init),
              let view = CADStandardView(rawValue: rawValue) else { return }
        onSnap?(view)
        viewsButton.selectItem(at: 0)
    }

    @objc private func selectNavigationPreset(_ sender: NSMenuItem) {
        guard let identifier = sender.representedObject as? String,
              let rawValue = identifier.split(separator: ":", maxSplits: 1).last.map(String.init),
              let preset = CADNavigationPreset(rawValue: rawValue) else { return }
        CADPreferences.setNavigationPreset(preset)
        viewsButton.selectItem(at: 0)
    }

    @objc private func selectLengthUnit(_ sender: NSMenuItem) {
        guard let identifier = sender.representedObject as? String,
              let rawValue = identifier.split(separator: ":", maxSplits: 1).last.map(String.init),
              let unit = CADLengthUnit(rawValue: rawValue) else { return }
        CADPreferences.setLengthUnit(unit)
        viewsButton.selectItem(at: 0)
    }

    @objc private func selectCameraProjection(_ sender: NSMenuItem) {
        guard let identifier = sender.representedObject as? String,
              let rawValue = identifier.split(separator: ":", maxSplits: 1).last.map(String.init),
              let projection = CADCameraProjection(rawValue: rawValue) else { return }
        CADPreferences.setCameraProjection(projection)
        onProjectionChange?(projection)
        viewsButton.selectItem(at: 0)
    }
}

@MainActor
private final class CADOrientationCubeSceneView: SCNView {
    var onSnap: ((CADStandardView) -> Void)?
    var onSnapCorner: ((SIMD3<Float>) -> Void)?
    var cameraOrientation = CADSceneFactory.cameraOrientation(offset: CADSceneFactory.defaultCameraOffset) {
        didSet { updateCamera() }
    }

    private let cameraNode = SCNNode()
    private let cubeCenter = SCNVector3(0.67, 0.67, 0.67)
    private let halfSize: Float = 0.67
    private let cornerRadius: CGFloat = 0.3

    override init(frame frameRect: NSRect, options: [String: Any]? = nil) {
        super.init(frame: frameRect, options: options)
        configureScene()
    }

    required init?(coder: NSCoder) { nil }

    private var trackingArea: NSTrackingArea?
    private var hoveredNode: SCNNode?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        setHovered(clickableNode(at: event))
    }

    override func mouseExited(with event: NSEvent) {
        setHovered(nil)
    }

    override func mouseDown(with event: NSEvent) {
        // The cube turns under the cursor after a snap, so drop the highlight
        // now; the next mouse move re-evaluates it.
        setHovered(nil)
        guard let hit = clickableNode(at: event), let name = hit.name else { return }
        if name.hasPrefix("view:"), let view = CADStandardView(rawValue: String(name.dropFirst(5))) {
            onSnap?(view)
        } else if name == "corner" {
            onSnapCorner?(simd_normalize(hit.simdPosition - cubeCenter.simdVector))
        }
    }

    /// The face or corner pad under the cursor, if any.
    private func clickableNode(at event: NSEvent) -> SCNNode? {
        let point = convert(event.locationInWindow, from: nil)
        let hits = hitTest(point, options: [
            .categoryBitMask: 2,
            .searchMode: SCNHitTestSearchMode.closest.rawValue
        ])
        return hits.first?.node
    }

    /// Tints the hovered face/pad with the accent colour so it reads as clickable.
    private func setHovered(_ node: SCNNode?) {
        guard node !== hoveredNode else { return }
        // Black is SceneKit's "no emission"; nil is not.
        hoveredNode?.geometry?.firstMaterial?.emission.contents = NSColor.black
        hoveredNode = node
        node?.geometry?.firstMaterial?.emission.contents = NSColor.controlAccentColor.withAlphaComponent(0.55)
        if node != nil { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        needsDisplay = true
    }

    private func configureScene() {
        let scene = SCNScene()
        scene.background.contents = NSColor.clear
        backgroundColor = .clear
        allowsCameraControl = false
        autoenablesDefaultLighting = false
        antialiasingMode = .multisampling4X
        self.scene = scene

        addCube(to: scene)
        addAxis(label: "X", direction: SIMD3<Float>(1, 0, 0), color: .systemRed, to: scene)
        addAxis(label: "Y", direction: SIMD3<Float>(0, 1, 0), color: .systemGreen, to: scene)
        addAxis(label: "Z", direction: SIMD3<Float>(0, 0, 1), color: .systemBlue, to: scene)

        cameraNode.camera = SCNCamera()
        cameraNode.camera?.usesOrthographicProjection = true
        cameraNode.camera?.orthographicScale = 2.55
        cameraNode.camera?.automaticallyAdjustsZRange = true
        scene.rootNode.addChildNode(cameraNode)
        pointOfView = cameraNode
        updateCamera()
    }

    private func addCube(to scene: SCNScene) {
        // A heavily rounded body, Onshape-style: flat face pads in the middle
        // of each side and small round pads on the corners.
        let cube = SCNBox(width: 1.34, height: 1.34, length: 1.34, chamferRadius: cornerRadius)
        let baseMaterial = SCNMaterial()
        baseMaterial.diffuse.contents = NSColor(calibratedWhite: 0.20, alpha: 1)
        baseMaterial.metalness.contents = 0.1
        baseMaterial.roughness.contents = 0.64
        cube.materials = [baseMaterial]
        let cubeNode = SCNNode(geometry: cube)
        cubeNode.position = cubeCenter
        cubeNode.categoryBitMask = 1
        scene.rootNode.addChildNode(cubeNode)

        // Each face's (right, up, normal) matches the standard view that looks at
        // it, so the labels read upright with Z up (Top/Bottom use ±Y as up).
        let x = SIMD3<Float>(1, 0, 0), y = SIMD3<Float>(0, 1, 0), z = SIMD3<Float>(0, 0, 1)
        addFace("Top", view: .top, position: SCNVector3(0.67, 0.67, 1.36), right: x, up: y, normal: z, to: scene)
        addFace("Bottom", view: .bottom, position: SCNVector3(0.67, 0.67, -0.02), right: x, up: -y, normal: -z, to: scene)
        addFace("Front", view: .front, position: SCNVector3(0.67, -0.02, 0.67), right: x, up: z, normal: -y, to: scene)
        addFace("Back", view: .back, position: SCNVector3(0.67, 1.36, 0.67), right: -x, up: z, normal: y, to: scene)
        addFace("Right", view: .right, position: SCNVector3(1.36, 0.67, 0.67), right: y, up: z, normal: x, to: scene)
        addFace("Left", view: .left, position: SCNVector3(-0.02, 0.67, 0.67), right: -y, up: z, normal: -x, to: scene)
        addCorners(to: scene)
    }

    /// A round pad sitting on each of the eight rounded corners; clicking one
    /// snaps to the isometric view looking from that corner.
    private func addCorners(to scene: SCNScene) {
        let radius = Float(cornerRadius)
        for sx: Float in [-1, 1] {
            for sy: Float in [-1, 1] {
                for sz: Float in [-1, 1] {
                    let sign = SIMD3<Float>(sx, sy, sz)
                    let normal = simd_normalize(sign)
                    let pad = SCNPlane(width: 0.3, height: 0.3)
                    pad.cornerRadius = 0.15
                    let material = SCNMaterial()
                    material.diffuse.contents = NSColor(calibratedWhite: 0.34, alpha: 1)
                    material.roughness.contents = 0.72
                    material.isDoubleSided = false
                    pad.materials = [material]
                    let node = SCNNode(geometry: pad)
                    node.name = "corner"
                    // The corner is a sphere octant of `radius` centred `radius`
                    // inside the corner; the pad sits just off its surface.
                    let sphereCenter = cubeCenter.simdVector + sign * (halfSize - radius)
                    node.simdPosition = sphereCenter + normal * (radius + 0.012)
                    node.simdOrientation = simd_quatf(from: SIMD3<Float>(0, 0, 1), to: normal)
                    node.categoryBitMask = 2
                    scene.rootNode.addChildNode(node)
                }
            }
        }
    }

    private func addFace(
        _ title: String,
        view: CADStandardView,
        position: SCNVector3,
        right: SIMD3<Float>,
        up: SIMD3<Float>,
        normal: SIMD3<Float>,
        to scene: SCNScene
    ) {
        let plane = SCNPlane(width: 0.8, height: 0.8)
        plane.cornerRadius = 0.12
        let material = SCNMaterial()
        material.diffuse.contents = faceImage(title)
        material.roughness.contents = 0.72
        material.isDoubleSided = false
        plane.materials = [material]
        let node = SCNNode(geometry: plane)
        node.name = "view:\(view.rawValue)"
        node.position = position
        node.simdOrientation = simd_quatf(simd_float3x3(columns: (right, up, normal)))
        node.categoryBitMask = 2
        scene.rootNode.addChildNode(node)
    }

    private func addAxis(label: String, direction: SIMD3<Float>, color: NSColor, to scene: SCNScene) {
        let material = SCNMaterial()
        material.diffuse.contents = color
        material.emission.contents = color
        material.lightingModel = .constant
        material.readsFromDepthBuffer = false
        material.writesToDepthBuffer = false

        let length: Float = 1.72
        let line = SCNCylinder(radius: 0.018, height: CGFloat(length))
        line.radialSegmentCount = 8
        line.materials = [material]
        let lineNode = SCNNode(geometry: line)
        lineNode.simdPosition = direction * (length * 0.5)
        lineNode.simdOrientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: direction)
        lineNode.renderingOrder = 20
        scene.rootNode.addChildNode(lineNode)

        let text = SCNText(string: label, extrusionDepth: 0.006)
        text.font = .systemFont(ofSize: 1, weight: .heavy)
        text.flatness = 0.04
        text.materials = [material]
        let textNode = SCNNode(geometry: text)
        textNode.simdPosition = direction * 1.88
        textNode.scale = SCNVector3(0.36, 0.36, 0.36)
        let bounds = textNode.boundingBox
        textNode.pivot = SCNMatrix4MakeTranslation(
            (bounds.min.x + bounds.max.x) * 0.5,
            (bounds.min.y + bounds.max.y) * 0.5,
            0
        )
        let billboard = SCNBillboardConstraint()
        billboard.freeAxes = .all
        textNode.constraints = [billboard]
        textNode.renderingOrder = 30
        scene.rootNode.addChildNode(textNode)
    }

    private func faceImage(_ title: String) -> NSImage {
        let size = NSSize(width: 160, height: 160)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor(calibratedWhite: 0.28, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 14, yRadius: 14).fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: title.count > 5 ? 25 : 30, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let textSize = title.size(withAttributes: attributes)
        title.draw(
            at: NSPoint(x: (size.width - textSize.width) / 2, y: (size.height - textSize.height) / 2),
            withAttributes: attributes
        )
        image.unlockFocus()
        return image
    }

    /// Mirrors the main camera's orientation (including roll) so the cube
    /// always shows exactly how the model is oriented on screen.
    private func updateCamera() {
        let backward = cameraOrientation.act(SIMD3<Float>(0, 0, 1))
        cameraNode.simdOrientation = cameraOrientation
        cameraNode.simdPosition = cubeCenter.simdVector + backward * 5
        setNeedsDisplay(bounds)
    }
}
