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
    var onProjectionChange: ((CADCameraProjection) -> Void)?

    var viewDirection = SCNVector3(1, -1, 1) {
        didSet { cubeView.viewDirection = viewDirection }
    }

    private let cubeView = CADOrientationCubeSceneView(frame: .zero, options: nil)
    private let viewsButton = NSPopUpButton(frame: .zero, pullsDown: true)

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
            cubeView.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            cubeView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -30),
            viewsButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            viewsButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
            viewsButton.widthAnchor.constraint(equalToConstant: 32),
            viewsButton.heightAnchor.constraint(equalToConstant: 24)
        ])
        cubeView.viewDirection = viewDirection
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

    func menuWillOpen(_ menu: NSMenu) {
        let selectedPreset = CADPreferences.navigationPreset
        let selectedProjection = CADPreferences.cameraProjection
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
            }
        }
    }

    @objc private func selectMenuItem(_ sender: NSPopUpButton) {
        guard let identifier = sender.selectedItem?.representedObject as? String else { return }
        if identifier.hasPrefix("view:"),
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
    var viewDirection = SCNVector3(1, -1, 1) { didSet { updateCamera() } }

    private let cameraNode = SCNNode()
    private let cubeCenter = SCNVector3(0.67, 0.67, 0.67)

    override init(frame frameRect: NSRect, options: [String: Any]? = nil) {
        super.init(frame: frameRect, options: options)
        configureScene()
    }

    required init?(coder: NSCoder) { nil }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let hits = hitTest(point, options: [
            .categoryBitMask: 2,
            .searchMode: SCNHitTestSearchMode.closest.rawValue
        ])
        guard let name = hits.first?.node.name,
              name.hasPrefix("view:"),
              let view = CADStandardView(rawValue: String(name.dropFirst(5))) else { return }
        onSnap?(view)
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
        let target = SCNNode()
        target.position = cubeCenter
        scene.rootNode.addChildNode(target)
        let lookAt = SCNLookAtConstraint(target: target)
        lookAt.isGimbalLockEnabled = true
        cameraNode.constraints = [lookAt]
        scene.rootNode.addChildNode(cameraNode)
        pointOfView = cameraNode
        updateCamera()
    }

    private func addCube(to scene: SCNScene) {
        let cube = SCNBox(width: 1.34, height: 1.34, length: 1.34, chamferRadius: 0.11)
        let baseMaterial = SCNMaterial()
        baseMaterial.diffuse.contents = NSColor(calibratedWhite: 0.20, alpha: 1)
        baseMaterial.metalness.contents = 0.1
        baseMaterial.roughness.contents = 0.64
        cube.materials = [baseMaterial]
        let cubeNode = SCNNode(geometry: cube)
        cubeNode.position = cubeCenter
        cubeNode.categoryBitMask = 1
        scene.rootNode.addChildNode(cubeNode)

        addFace("Top", view: .top, position: SCNVector3(0.67, 0.67, 1.36), euler: SCNVector3Zero, to: scene)
        addFace("Bottom", view: .bottom, position: SCNVector3(0.67, 0.67, -0.02), euler: SCNVector3(0, Float.pi, 0), to: scene)
        addFace("Front", view: .front, position: SCNVector3(0.67, -0.02, 0.67), euler: SCNVector3(Float.pi / 2, 0, 0), to: scene)
        addFace("Back", view: .back, position: SCNVector3(0.67, 1.36, 0.67), euler: SCNVector3(-Float.pi / 2, 0, 0), to: scene)
        addFace("Right", view: .right, position: SCNVector3(1.36, 0.67, 0.67), euler: SCNVector3(0, Float.pi / 2, 0), to: scene)
        addFace("Left", view: .left, position: SCNVector3(-0.02, 0.67, 0.67), euler: SCNVector3(0, -Float.pi / 2, 0), to: scene)
    }

    private func addFace(
        _ title: String,
        view: CADStandardView,
        position: SCNVector3,
        euler: SCNVector3,
        to scene: SCNScene
    ) {
        let plane = SCNPlane(width: 1.12, height: 1.12)
        plane.cornerRadius = 0.05
        let material = SCNMaterial()
        material.diffuse.contents = faceImage(title)
        material.roughness.contents = 0.72
        material.isDoubleSided = false
        plane.materials = [material]
        let node = SCNNode(geometry: plane)
        node.name = "view:\(view.rawValue)"
        node.position = position
        node.eulerAngles = euler
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

    private func updateCamera() {
        let direction = normalized(viewDirection)
        cameraNode.position = SCNVector3(
            cubeCenter.x + direction.x * 5,
            cubeCenter.y + direction.y * 5,
            cubeCenter.z + direction.z * 5
        )
        setNeedsDisplay(bounds)
    }
}

private func normalized(_ vector: SCNVector3) -> SCNVector3 {
    let length = max(sqrt(vector.x * vector.x + vector.y * vector.y + vector.z * vector.z), 0.0001)
    return SCNVector3(vector.x / length, vector.y / length, vector.z / length)
}
