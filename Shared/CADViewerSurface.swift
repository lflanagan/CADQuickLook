import AppKit
import SceneKit

/// Viewer surface shared by the app and Quick Look extension.
@MainActor
final class CADViewerSurface: NSGlassEffectView {
    private let sceneView = InteractiveCADView()
    private let viewerContent = NSView()
    private let viewCube = CADOrientationWidgetView()
    private let resultCard = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let valueLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private var measurementSession: SmartMeasurementSession?

    private(set) var representedURL: URL?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureView()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(cameraProjectionDidChange(_:)),
            name: .cadCameraProjectionDidChange,
            object: nil
        )
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshGlassPassThrough()
        Task { @MainActor [weak self] in
            self?.refreshGlassPassThrough()
        }
    }

    func refreshGlassPassThrough() {
        guard let window else { return }
        window.isOpaque = false
        window.backgroundColor = .clear

        guard Bundle.main.bundleIdentifier == CADPreferences.suiteName else { return }
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        cornerRadius = 0
    }

    func display(_ asset: CADModelAsset) {
        representedURL = asset.url
        let scene = CADSceneFactory.makeScene(for: asset)
        sceneView.scene = scene
        sceneView.asset = asset
        sceneView.pointOfView = scene.rootNode.childNode(withName: "Camera", recursively: true)
        sceneView.setCameraProjection(CADPreferences.cameraProjection)

        let session = SmartMeasurementSession(asset: asset)
        sceneView.onHover = session.hover
        sceneView.onSelect = session.select
        session.onResult = { [weak self, weak sceneView] result in
            self?.show(result)
            sceneView?.updateMeasurementOverlay(result)
        }
        measurementSession = session
        show(nil)

        viewCube.onSnap = sceneView.snap
        viewCube.onProjectionChange = sceneView.setCameraProjection
        sceneView.onViewDirectionChanged = { [weak viewCube] direction in
            viewCube?.viewDirection = direction
        }
    }

    private func configureView() {
        style = .regular
        cornerRadius = 22
        viewerContent.wantsLayer = true
        viewerContent.layer?.backgroundColor = NSColor.clear.cgColor
        contentView = viewerContent

        sceneView.translatesAutoresizingMaskIntoConstraints = false
        sceneView.allowsCameraControl = false
        sceneView.autoenablesDefaultLighting = false
        sceneView.antialiasingMode = .multisampling4X
        sceneView.backgroundColor = .clear
        sceneView.rendersContinuously = false
        sceneView.preferredFramesPerSecond = 60
        viewerContent.addSubview(sceneView)

        viewCube.translatesAutoresizingMaskIntoConstraints = false
        viewerContent.addSubview(viewCube)
        configureResultCard()

        NSLayoutConstraint.activate([
            sceneView.leadingAnchor.constraint(equalTo: viewerContent.leadingAnchor),
            sceneView.trailingAnchor.constraint(equalTo: viewerContent.trailingAnchor),
            sceneView.topAnchor.constraint(equalTo: viewerContent.topAnchor),
            sceneView.bottomAnchor.constraint(equalTo: viewerContent.bottomAnchor),
            viewCube.topAnchor.constraint(equalTo: viewerContent.topAnchor, constant: 16),
            viewCube.trailingAnchor.constraint(equalTo: viewerContent.trailingAnchor, constant: -16)
        ])
    }

    private func configureResultCard() {
        resultCard.translatesAutoresizingMaskIntoConstraints = false
        resultCard.isHidden = true

        titleLabel.font = .boldSystemFont(ofSize: 14)
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.maximumNumberOfLines = 2

        for label in [titleLabel, valueLabel, detailLabel] {
            label.wantsLayer = true
            label.layer?.shadowColor = NSColor.black.withAlphaComponent(0.45).cgColor
            label.layer?.shadowOpacity = 1
            label.layer?.shadowRadius = 2
            label.layer?.shadowOffset = CGSize(width: 0, height: -1)
        }

        let stack = NSStackView(views: [titleLabel, valueLabel, detailLabel])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        resultCard.addSubview(stack)
        viewerContent.addSubview(resultCard)

        NSLayoutConstraint.activate([
            resultCard.trailingAnchor.constraint(equalTo: viewerContent.trailingAnchor, constant: -18),
            resultCard.bottomAnchor.constraint(equalTo: viewerContent.bottomAnchor, constant: -18),
            resultCard.widthAnchor.constraint(greaterThanOrEqualToConstant: 240),
            stack.leadingAnchor.constraint(equalTo: resultCard.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: resultCard.trailingAnchor),
            stack.topAnchor.constraint(equalTo: resultCard.topAnchor),
            stack.bottomAnchor.constraint(equalTo: resultCard.bottomAnchor)
        ])
    }

    @objc private func cameraProjectionDidChange(_ notification: Notification) {
        guard let projection = notification.object as? CADCameraProjection else { return }
        sceneView.setCameraProjection(projection)
    }

    private func show(_ result: SmartMeasurementResult?) {
        guard let result else {
            resultCard.isHidden = true
            return
        }
        titleLabel.stringValue = result.title
        var rows = "\(result.primaryLabel)    \(result.primaryValue)"
        if let label = result.secondaryLabel, let value = result.secondaryValue {
            rows += "\n\(label)    \(value)"
        }
        valueLabel.stringValue = rows
        detailLabel.stringValue = result.detail ?? ""
        detailLabel.isHidden = result.detail == nil
        resultCard.isHidden = false
    }
}
