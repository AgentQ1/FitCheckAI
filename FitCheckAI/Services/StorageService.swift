import UIKit

final class StorageService {
    // Default upload target: long edge 1024 px, JPEG quality ~0.65.
    // On a typical iPhone photo this brings 3–4 MB images down to ~150–300 KB,
    // which is the biggest single win for upload speed.
    static let defaultMaxLongEdge: CGFloat = 1024
    static let defaultJPEGQuality: CGFloat = 0.65

    // Resize on the calling thread (kept for backward compatibility).
    func prepareForUpload(_ image: UIImage, maxLongEdge: CGFloat = StorageService.defaultMaxLongEdge) -> UIImage {
        let size = image.size
        let scale = min(maxLongEdge / max(size.width, size.height), 1.0)
        guard scale < 1.0 else { return image }

        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1   // avoid 2x/3x screen scale blowing the pixel count back up
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }

    // Resize off the main thread. Call this from `Task.detached` in the view layer.
    func prepareForUploadAsync(_ image: UIImage, maxLongEdge: CGFloat = StorageService.defaultMaxLongEdge) async -> UIImage {
        await Task.detached(priority: .userInitiated) {
            self.prepareForUpload(image, maxLongEdge: maxLongEdge)
        }.value
    }

    func generateThumbnail(_ image: UIImage, size: CGFloat = 400) -> UIImage {
        return prepareForUpload(image, maxLongEdge: size)
    }

    func jpegData(_ image: UIImage, quality: CGFloat = StorageService.defaultJPEGQuality) -> Data? {
        image.jpegData(compressionQuality: quality)
    }

    func estimatedFileSizeBytes(_ image: UIImage) -> Int {
        jpegData(image)?.count ?? 0
    }
}
