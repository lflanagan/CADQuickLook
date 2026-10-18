import AppKit
import QuickLookThumbnailing

final class ThumbnailProvider: QLThumbnailProvider {
    /// Finder asks for many thumbnails at once (every icon in a folder).
    /// Each STEP import peaks at several hundred megabytes to a gigabyte, so
    /// run them one at a time to keep the extension's footprint to one
    /// model. Import already serialises on the bridge's translation lock and
    /// tessellation uses every core, so little throughput is lost.
    private static let oneAtATime = DispatchSemaphore(value: 1)

    override func provideThumbnail(
        for request: QLFileThumbnailRequest,
        _ handler: @escaping (QLThumbnailReply?, (any Error)?) -> Void
    ) {
        Self.oneAtATime.wait()
        defer { Self.oneAtATime.signal() }
        do {
            let asset = try CADModelAsset(url: request.fileURL, quality: .thumbnail)
            let image = CADSceneFactory.renderThumbnail(
                for: asset,
                size: request.maximumSize,
                scale: request.scale
            )
            var proposed = CGRect(origin: .zero, size: image.size)
            guard let cgImage = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil) else {
                throw CADModelError.loadFailed("Could not render the CAD thumbnail.")
            }
            let reply = QLThumbnailReply(contextSize: request.maximumSize) { context in
                // The context's user space is not guaranteed to be in points;
                // the clip covers exactly the full thumbnail, so paint that.
                let rect = context.boundingBoxOfClipPath
                context.setFillColor(NSColor(calibratedWhite: 0.10, alpha: 1).cgColor)
                context.fill(rect)
                context.interpolationQuality = .high
                context.draw(cgImage, in: rect)
                return true
            }
            handler(reply, nil)
        } catch {
            handler(nil, error)
        }
    }
}
