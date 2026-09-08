import AppKit
import SceneKit

/// Viewer content shared by the app and Quick Look extension. Draws nothing of
/// its own: it is transparent and sits on a `CADGlassBackdrop` supplied by the host.
@MainActor
final class CADViewerSurface: NSView {
    private let sceneView = InteractiveCADView()
    private let viewCube = CADOrientationWidgetView()
    private let resultCard = NSView()
    private let measureLabel = NSTextField(labelWithString: "")
    private let measureValue = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let detailValue = NSTextField(labelWithString: "")
    private let detailRow = NSStackView()
    private var measurementSession: SmartMeasurementSession?
    private var lastResult: SmartMeasurementResult?
    private let loadingLabel = NSTextField(labelWithString: "")
    private let loadingBar = NSProgressIndicator()
    private let buildStampLabel = NSTextField(labelWithString: CADBuildInfo.stamp)
    /// File icon + name in the title strip, inline with the traffic lights.
    private let fileIcon = NSImageView()
    private let fileNameLabel = NSTextField(labelWithString: "")
    /// Left inset of the file name: past the traffic lights (app window) or
    /// flush with the panel edge (Quick Look has no traffic lights).
    private var fileNameLeading: NSLayoutConstraint?

    /// Shows the build stamp in the bottom-left corner. The app draws its own
    /// (in every window state), so only Quick Look turns this on.
    var showsBuildStamp = false {
        didSet {
            buildStampLabel.isHidden = !showsBuildStamp
            fileNameLeading?.constant = showsBuildStamp ? 16 : 84
        }
    }

    private(set) var representedURL: URL?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureView()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(cameraProjectionDidChange(_:)), name: .cadCameraProjectionDidChange, object: nil)
        center.addObserver(self, selector: #selector(measurementSettingsDidChange(_:)), name: .cadLengthUnitDidChange, object: nil)
        center.addObserver(self, selector: #selector(measurementSettingsDidChange(_:)), name: .cadMeasurementOptionsDidChange, object: nil)
        center.addObserver(self, selector: #selector(displayOptionsDidChange(_:)), name: .cadDisplayOptionsDidChange, object: nil)
        center.addObserver(self, selector: #selector(viewCommand(_:)), name: .cadViewCommand, object: nil)
    }

    /// Gives keyboard focus to the 3D view (Quick Look never clicks it first).
    func focusViewer() {
        window?.makeFirstResponder(sceneView)
    }

    @objc private func viewCommand(_ notification: Notification) {
        guard let command = notification.object as? CADViewCommand,
              window?.isKeyWindow == true || window?.isMainWindow == true else { return }
        sceneView.perform(command)
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
        fileNameLabel.stringValue = asset.url.lastPathComponent
        fileIcon.image = NSWorkspace.shared.icon(forFile: asset.url.path)
        fileIcon.isHidden = false
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
        sceneView.onDeselect = session.deselect
        session.onResult = { [weak self, weak sceneView] result in
            self?.show(result)
            sceneView?.updateMeasurementOverlay(result)
        }
        session.onPendingChanged = { [weak sceneView] target in
            sceneView?.updatePendingSelection(target)
        }
        measurementSession = session
        show(nil)

        viewCube.onSnap = sceneView.snap
        viewCube.onSnapCorner = sceneView.snap(toCameraOffset:)
        sceneView.onCopy = { [weak self] in self?.lastResult?.clipboardText }
        sceneView.onDidCopy = { [weak self] in self?.flashCopied() }
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

        fileIcon.translatesAutoresizingMaskIntoConstraints = false
        fileIcon.imageScaling = .scaleProportionallyDown
        fileIcon.isHidden = true
        addSubview(fileIcon)
        fileNameLabel.translatesAutoresizingMaskIntoConstraints = false
        fileNameLabel.font = helvetica(size: 13)
        fileNameLabel.textColor = .secondaryLabelColor
        fileNameLabel.lineBreakMode = .byTruncatingMiddle
        fileNameLabel.maximumNumberOfLines = 1
        addSubview(fileNameLabel)
        let leading = fileIcon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 84)
        fileNameLeading = leading

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
            viewCube.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            viewCube.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            loadingBar.centerXAnchor.constraint(equalTo: centerXAnchor),
            loadingBar.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -8),
            loadingBar.widthAnchor.constraint(equalToConstant: 260),
            loadingLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            loadingLabel.topAnchor.constraint(equalTo: loadingBar.bottomAnchor, constant: 10),
            buildStampLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            buildStampLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            leading,
            fileIcon.centerYAnchor.constraint(equalTo: topAnchor, constant: 15),
            fileIcon.widthAnchor.constraint(equalToConstant: 16),
            fileIcon.heightAnchor.constraint(equalToConstant: 16),
            fileNameLabel.leadingAnchor.constraint(equalTo: fileIcon.trailingAnchor, constant: 6),
            fileNameLabel.centerYAnchor.constraint(equalTo: fileIcon.centerYAnchor),
            fileNameLabel.trailingAnchor.constraint(lessThanOrEqualTo: viewCube.leadingAnchor, constant: -12)
        ])
    }

    /// One label and one value, bottom-right. Helvetica, no backing panel.
    private func configureResultCard() {
        resultCard.translatesAutoresizingMaskIntoConstraints = false
        resultCard.isHidden = true

        measureLabel.font = helvetica(size: 13)
        measureLabel.textColor = .secondaryLabelColor
        measureValue.font = helvetica(size: 17, bold: true)
        measureValue.textColor = .labelColor
        measureValue.alignment = .right
        detailLabel.font = helvetica(size: 12)
        detailLabel.textColor = .secondaryLabelColor
        detailValue.font = helvetica(size: 14, bold: true)
        detailValue.textColor = .secondaryLabelColor
        detailValue.alignment = .right
        for label in [measureLabel, measureValue, detailLabel, detailValue] {
            label.wantsLayer = true
            label.layer?.shadowColor = NSColor.black.withAlphaComponent(0.55).cgColor
            label.layer?.shadowOpacity = 1
            label.layer?.shadowRadius = 2.5
            label.layer?.shadowOffset = CGSize(width: 0, height: -1)
        }

        let row = NSStackView(views: [measureLabel, measureValue])
        row.orientation = .horizontal
        row.alignment = .lastBaseline
        row.spacing = 18
        detailRow.setViews([detailLabel, detailValue], in: .leading)
        detailRow.orientation = .horizontal
        detailRow.alignment = .lastBaseline
        detailRow.spacing = 18
        detailRow.isHidden = true
        let rows = NSStackView(views: [row, detailRow])
        rows.translatesAutoresizingMaskIntoConstraints = false
        rows.orientation = .vertical
        rows.alignment = .trailing
        rows.spacing = 4
        resultCard.addSubview(rows)
        addSubview(resultCard)

        NSLayoutConstraint.activate([
            resultCard.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            resultCard.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -18),
            rows.leadingAnchor.constraint(equalTo: resultCard.leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: resultCard.trailingAnchor),
            rows.topAnchor.constraint(equalTo: resultCard.topAnchor),
            rows.bottomAnchor.constraint(equalTo: resultCard.bottomAnchor)
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

    @objc private func measurementSettingsDidChange(_ notification: Notification) {
        measurementSession?.refresh()
    }

    @objc private func displayOptionsDidChange(_ notification: Notification) {
        sceneView.applyDisplayOptions(CADPreferences.displayOptions)
    }

    private var copyFlashTimer: Timer?

    /// Cmd+C feedback: the value snaps to orange once the pasteboard has it,
    /// then eases back to white (cubic ease-out, about half a second).
    private func flashCopied() {
        guard !resultCard.isHidden else { return }
        copyFlashTimer?.invalidate()
        let from = NSColor.systemOrange.usingColorSpace(.sRGB) ?? .systemOrange
        let to = NSColor.labelColor.usingColorSpace(.sRGB) ?? .labelColor
        let duration = 0.55
        let start = CACurrentMediaTime()
        measureValue.textColor = from
        copyFlashTimer = Timer.scheduledTimer(withTimeInterval: 1 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let t = min(1, (CACurrentMediaTime() - start) / duration)
                let eased = 1 - pow(1 - t, 3)
                self.measureValue.textColor = from.blended(withFraction: eased, of: to) ?? to
                if t >= 1 {
                    self.copyFlashTimer?.invalidate()
                    self.copyFlashTimer = nil
                }
            }
        }
    }

    private func show(_ result: SmartMeasurementResult?) {
        lastResult = result
        guard let result else {
            resultCard.isHidden = true
            return
        }
        measureLabel.stringValue = result.label
        measureValue.stringValue = result.value.formatted
        if let label = result.detailLabel, let value = result.detailValue {
            detailLabel.stringValue = label
            detailValue.stringValue = value.formatted
            detailRow.isHidden = false
        } else {
            detailRow.isHidden = true
        }
        copyFlashTimer?.invalidate()
        copyFlashTimer = nil
        measureValue.textColor = .labelColor
        resultCard.isHidden = false
    }
}
