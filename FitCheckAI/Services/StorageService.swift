import UIKit
import ImageIO

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

    func jpegData(_ image: UIImage, quality: CGFloat = StorageService.defaultJPEGQuality) -> Data? {
        image.jpegData(compressionQuality: quality)
    }

    /// Decodes `data` DIRECTLY at a downsampled size via ImageIO, so a 12-MP gallery
    /// photo never inflates into a ~50 MB full-resolution bitmap just to be displayed
    /// and then shrunk for upload. EXIF orientation is applied. Falls back to a plain
    /// decode if thumbnailing fails. Safe to call off the main thread.
    func downsampledImage(from data: Data, maxLongEdge: CGFloat = 1280) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            return UIImage(data: data)
        }
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,        // honor EXIF orientation
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxLongEdge,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else {
            return UIImage(data: data)
        }
        return UIImage(cgImage: cg)
    }

    func estimatedFileSizeBytes(_ image: UIImage) -> Int {
        jpegData(image)?.count ?? 0
    }
}
