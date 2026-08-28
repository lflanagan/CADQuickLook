import AppKit
import QuickLookThumbnailing

final class ThumbnailProvider: QLThumbnailProvider {
    override func provideThumbnail(
        for request: QLFileThumbnailRequest,
        _ handler: @escaping (QLThumbnailReply?, (any Error)?) -> Void
    ) {
        do {
            let asset = try CADModelAsset(url: request.fileURL)
            let image = CADSceneFactory.renderThumbnail(
                for: asset,
                size: request.maximumSize,
                scale: request.scale
            )
            var proposed = CGRect(origin: .zero, size: image.size)
            guard let cgImage = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil) else {
                throw CADModelError.loadFailed("Could not render the CAD thumbnail.")
            }
            let size = request.maximumSize
            let reply = QLThumbnailReply(contextSize: size) { context in
                context.setFillColor(NSColor(calibratedWhite: 0.10, alpha: 1).cgColor)
                context.fill(CGRect(origin: .zero, size: size))
                context.interpolationQuality = .high
                context.draw(cgImage, in: CGRect(origin: .zero, size: size))
                return true
            }
            handler(reply, nil)
        } catch {
            handler(nil, error)
        }
    }
}
