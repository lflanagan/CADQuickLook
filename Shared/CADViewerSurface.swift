import AppKit
import SceneKit

/// Viewer content shared by the app and Quick Look extension. Draws nothing of
/// its own: it is transparent and sits on a `CADGlassBackdrop` supplied by the host.
@MainActor
final class CADViewerSurface: NSView {
    private let sceneView = InteractiveCADView()
    private let viewCube = CADOrientationWidgetView()
    private let resultCard = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let primaryLabel = NSTextField(labelWithString: "")
    private let primaryValue = NSTextField(labelWithString: "")
    private let secondaryLabel = NSTextField(labelWithString: "")
    private let secondaryValue = NSTextField(labelWithString: "")
    private var secondaryRow: NSGridRow?
    private var measurementSession: SmartMeasurementSession?
    private var lastResult: SmartMeasurementResult?
    private let loadingLabel = NSTextField(labelWithString: "")
    private let loadingBar = NSProgressIndicator()
    private let buildStampLabel = NSTextField(labelWithString: CADBuildInfo.stamp)

    /// Shows the build stamp in the bottom-left corner. The app draws its own
    /// (in every window state), so only Quick Look turns this on.
    var showsBuildStamp = false {
        didSet { buildStampLabel.isHidden = !showsBuildStamp }
    }

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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(lengthUnitDidChange(_:)),
            name: .cadLengthUnitDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(displayOptionsDidChange(_:)),
            name: .cadDisplayOptionsDidChange,
            object: nil
        )
    }

    required init?(coder: NSCoder) { nil }

    /// Shows a loading status over the (empty) viewer; pass nil to hide it.
    func showLoading(_ status: String?, fraction: Double? = nil) {
        loadingLabel.isHidden = status == nil
        loadingBar.isHidden = status == nil
        guard let status else { return }
        loadingLabel.stringValue = status
        if let fraction {
            loadingBar.isIndeterminate = false
            loadingBar.doubleValue = fraction
        } else {
            loadingBar.isIndeterminate = true
            loadingBar.startAnimation(nil)
        }
    }

    func display(_ asset: CADModelAsset) {
        showLoading(nil)
        representedURL = asset.url
        let options = CADPreferences.displayOptions
        let scene = CADSceneFactory.makeScene(for: asset, options: options)
        sceneView.scene = scene
        sceneView.applyDisplayOptions(options)
        sceneView.asset = asset
        sceneView.pointOfView = scene.rootNode.childNode(withName: "Camera", recursively: true)
        viewCube.isPlanar = asset.isPlanar
        if !asset.isPlanar {
            sceneView.setCameraProjection(CADPreferences.cameraProjection)
        }

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
        viewCube.onSnapCorner = sceneView.snap(toCameraOffset:)
        sceneView.onCopy = { [weak self] in self?.lastResult?.primaryValue.formatted }
        viewCube.onProjectionChange = sceneView.setCameraProjection
        sceneView.onCameraOrientationChanged = { [weak viewCube] orientation in
            viewCube?.cameraOrientation = orientation
        }
    }

    private func configureView() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        sceneView.translatesAutoresizingMaskIntoConstraints = false
        sceneView.allowsCameraControl = false
        sceneView.autoenablesDefaultLighting = false
        sceneView.antialiasingMode = .multisampling4X
        sceneView.backgroundColor = .clear
        sceneView.rendersContinuously = false
        sceneView.preferredFramesPerSecond = 60
        addSubview(sceneView)

        viewCube.translatesAutoresizingMaskIntoConstraints = false
        addSubview(viewCube)
        configureResultCard()

        loadingLabel.translatesAutoresizingMaskIntoConstraints = false
        loadingLabel.font = helvetica(size: 13)
        loadingLabel.textColor = .secondaryLabelColor
        loadingLabel.alignment = .center
        loadingLabel.isHidden = true
        loadingBar.translatesAutoresizingMaskIntoConstraints = false
        loadingBar.style = .bar
        loadingBar.minValue = 0
        loadingBar.maxValue = 1
        loadingBar.isHidden = true
        addSubview(loadingBar)
        addSubview(loadingLabel)

        buildStampLabel.translatesAutoresizingMaskIntoConstraints = false
        buildStampLabel.font = helvetica(size: 10)
        buildStampLabel.textColor = .tertiaryLabelColor
        buildStampLabel.alphaValue = 0.6
        buildStampLabel.isHidden = true
        addSubview(buildStampLabel)

        NSLayoutConstraint.activate([
            sceneView.leadingAnchor.constraint(equalTo: leadingAnchor),
            sceneView.trailingAnchor.constraint(equalTo: trailingAnchor),
            sceneView.topAnchor.constraint(equalTo: topAnchor),
            sceneView.bottomAnchor.constraint(equalTo: bottomAnchor),
            viewCube.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            viewCube.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            loadingBar.centerXAnchor.constraint(equalTo: centerXAnchor),
            loadingBar.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -8),
            loadingBar.widthAnchor.constraint(equalToConstant: 260),
            loadingLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            loadingLabel.topAnchor.constraint(equalTo: loadingBar.bottomAnchor, constant: 10),
            buildStampLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            buildStampLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10)
        ])
    }

    private func configureResultCard() {
        resultCard.translatesAutoresizingMaskIntoConstraints = false
        resultCard.isHidden = true

        titleLabel.font = helvetica(size: 12, bold: true)
        titleLabel.textColor = .secondaryLabelColor
        for label in [primaryLabel, secondaryLabel] {
            label.font = helvetica(size: 13)
            label.textColor = .secondaryLabelColor
        }
        for value in [primaryValue, secondaryValue] {
            value.font = helvetica(size: 17, bold: true)
            value.textColor = .labelColor
            value.alignment = .right
        }
        for label in [titleLabel, primaryLabel, primaryValue, secondaryLabel, secondaryValue] {
            label.wantsLayer = true
            label.layer?.shadowColor = NSColor.black.withAlphaComponent(0.55).cgColor
            label.layer?.shadowOpacity = 1
            label.layer?.shadowRadius = 2.5
            label.layer?.shadowOffset = CGSize(width: 0, height: -1)
        }

        let grid = NSGridView(views: [
            [primaryLabel, primaryValue],
            [secondaryLabel, secondaryValue]
        ])
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 4
        grid.columnSpacing = 18
        grid.column(at: 0).xPlacement = .leading
        grid.column(at: 1).xPlacement = .trailing
        grid.rowAlignment = .lastBaseline
        secondaryRow = grid.row(at: 1)

        let stack = NSStackView(views: [titleLabel, grid])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        resultCard.addSubview(stack)
        addSubview(resultCard)

        NSLayoutConstraint.activate([
            resultCard.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            resultCard.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -18),
            resultCard.widthAnchor.constraint(greaterThanOrEqualToConstant: 240),
            grid.widthAnchor.constraint(equalTo: stack.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: resultCard.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: resultCard.trailingAnchor),
            stack.topAnchor.constraint(equalTo: resultCard.topAnchor),
            stack.bottomAnchor.constraint(equalTo: resultCard.bottomAnchor)
        ])
    }

    private func helvetica(size: CGFloat, bold: Bool = false) -> NSFont {
        NSFont(name: bold ? "Helvetica-Bold" : "Helvetica", size: size)
            ?? .systemFont(ofSize: size, weight: bold ? .bold : .regular)
    }

    @objc private func cameraProjectionDidChange(_ notification: Notification) {
        guard let projection = notification.object as? CADCameraProjection,
              sceneView.asset?.isPlanar != true else { return }
        sceneView.setCameraProjection(projection)
    }

    @objc private func lengthUnitDidChange(_ notification: Notification) {
        show(lastResult)
    }

    @objc private func displayOptionsDidChange(_ notification: Notification) {
        sceneView.applyDisplayOptions(CADPreferences.displayOptions)
    }

    private func show(_ result: SmartMeasurementResult?) {
        lastResult = result
        guard let result else {
            resultCard.isHidden = true
            return
        }
        titleLabel.stringValue = result.title.uppercased()
        primaryLabel.stringValue = result.primaryLabel
        primaryValue.stringValue = result.primaryValue.formatted
        if let label = result.secondaryLabel, let value = result.secondaryValue {
            secondaryLabel.stringValue = label
            secondaryValue.stringValue = value.formatted
            secondaryRow?.isHidden = false
        } else {
            secondaryRow?.isHidden = true
        }
        resultCard.isHidden = false
    }
}
