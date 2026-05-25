import UIKit

final class StorageService {
    // Resize and compress image before upload
    func prepareForUpload(_ image: UIImage, maxLongEdge: CGFloat = 2048) -> UIImage {
        let size = image.size
        let scale = min(maxLongEdge / max(size.width, size.height), 1.0)
        guard scale < 1.0 else { return image }

        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }

    func generateThumbnail(_ image: UIImage, size: CGFloat = 400) -> UIImage {
        return prepareForUpload(image, maxLongEdge: size)
    }

    func jpegData(_ image: UIImage, quality: CGFloat = 0.85) -> Data? {
        image.jpegData(compressionQuality: quality)
    }

    func estimatedFileSizeBytes(_ image: UIImage) -> Int {
        jpegData(image)?.count ?? 0
    }
}
