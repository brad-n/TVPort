import UIKit

/// Bundled images, decoded once.
enum Art {
    private static let cache = NSCache<NSString, UIImage>()
    static func image(_ path: String) -> UIImage? {
        guard !path.isEmpty else { return nil }
        if let hit = cache.object(forKey: path as NSString) { return hit }
        guard let image = UIImage(contentsOfFile: Catalog.folder.appendingPathComponent(path).path) else { return nil }
        cache.setObject(image, forKey: path as NSString)
        return image
    }
}
