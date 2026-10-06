import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import Supabase
import SwiftUI
import UIKit

/// In-memory thumbnails and their average colors, keyed by storage path.
@MainActor
final class MediaCache {
    static let shared = MediaCache()

    private let thumbnails = NSCache<NSString, UIImage>()
    private let fullImages = NSCache<NSString, UIImage>()
    private var tints: [String: Color] = [:]

    private init() {
        thumbnails.countLimit = 400
        fullImages.countLimit = 8
    }

    func cachedThumbnail(for item: MediaItem) -> UIImage? {
        thumbnails.object(forKey: item.storagePath as NSString)
    }

    func tint(for item: MediaItem) -> Color? { tints[item.storagePath] }

    /// A small square-ish preview: a downscaled photo, or a frame from a video.
    func thumbnail(for item: MediaItem, url: URL) async -> UIImage? {
        let key = item.storagePath as NSString
        if let image = thumbnails.object(forKey: key) { return image }
        let image = item.isVideo
            ? await MediaTools.videoFrame(url: url, maxPixel: 480)
            : await MediaTools.downloadImage(url: url, maxPixel: 480)
        if let image {
            thumbnails.setObject(image, forKey: key)
            if tints[item.storagePath] == nil, let color = MediaTools.averageColor(of: image) {
                tints[item.storagePath] = color
            }
        }
        return image
    }

    /// A screen-sized photo for the viewer.
    func fullImage(for item: MediaItem, url: URL) async -> UIImage? {
        let key = item.storagePath as NSString
        if let image = fullImages.object(forKey: key) { return image }
        let image = await MediaTools.downloadImage(url: url, maxPixel: 2048)
        if let image { fullImages.setObject(image, forKey: key) }
        return image
    }
}

/// Profile photos from the private `avatars` bucket. Keys include the
/// profile's `updated_at`, so a new photo is fetched once the profile changes.
@MainActor
final class AvatarCache {
    static let shared = AvatarCache()

    private let images = NSCache<NSString, UIImage>()
    private var loading: [String: Task<UIImage?, Never>] = [:]
    private var keysByPath: [String: Set<String>] = [:]

    private init() {
        images.countLimit = 100
    }

    func cached(path: String, version: String) -> UIImage? {
        images.object(forKey: cacheKey(path, version) as NSString)
    }

    func image(path: String, version: String) async -> UIImage? {
        let key = cacheKey(path, version)
        if let image = images.object(forKey: key as NSString) { return image }
        if let inFlight = loading[key] { return await inFlight.value }
        let task = Task<UIImage?, Never> {
            guard let data = try? await supabase.storage.from(Config.avatarBucket).download(path: path),
                  let image = UIImage(data: data) else { return nil }
            return MediaTools.downscale(image, maxPixel: 256)
        }
        loading[key] = task
        let image = await task.value
        loading[key] = nil
        if let image {
            images.setObject(image, forKey: key as NSString)
            keysByPath[path, default: []].insert(key)
        }
        return image
    }

    /// Drops every cached version of a photo (after replacing or removing it).
    func forget(path: String) {
        for key in keysByPath[path] ?? [] { images.removeObject(forKey: key as NSString) }
        keysByPath[path] = nil
    }

    private func cacheKey(_ path: String, _ version: String) -> String { "\(path)#\(version)" }
}

enum MediaTools {
    private static let ciContext = CIContext(options: [.workingColorSpace: NSNull()])

    static func downloadImage(url: URL, maxPixel: CGFloat) async -> UIImage? {
        guard let response = try? await URLSession.shared.data(from: url),
              let image = UIImage(data: response.0) else { return nil }
        return downscale(image, maxPixel: maxPixel)
    }

    static func videoFrame(url: URL, maxPixel: CGFloat) async -> UIImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        guard let frame = try? await generator.image(at: CMTime(seconds: 0.3, preferredTimescale: 600)) else { return nil }
        return UIImage(cgImage: frame.image)
    }

    /// Redraws upright at most `maxPixel` on the long side.
    static func downscale(_ image: UIImage, maxPixel: CGFloat) -> UIImage {
        let size = image.size
        let scale = min(1, maxPixel / max(size.width, size.height, 1))
        guard scale < 1 else { return image }
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    /// The photo's average color via CIAreaAverage, used to tint the viewer.
    static func averageColor(of image: UIImage) -> Color? {
        guard let input = CIImage(image: image) else { return nil }
        let filter = CIFilter.areaAverage()
        filter.inputImage = input
        filter.extent = input.extent
        guard let output = filter.outputImage else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        ciContext.render(output, toBitmap: &pixel, rowBytes: 4,
                         bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        return Color(.sRGB, red: Double(pixel[0]) / 255, green: Double(pixel[1]) / 255,
                     blue: Double(pixel[2]) / 255, opacity: 1)
    }

    // MARK: Preparing uploads

    /// Photos are re-encoded as JPEG (≤ 2560 px) so the wall display can always
    /// decode them; HEIC isn't reliably supported there. Keeps EXIF capture date.
    static func preparePhoto(_ data: Data) -> (data: Data, metadata: MediaMetadata)? {
        guard let image = UIImage(data: data) else { return nil }
        let resized = downscale(image, maxPixel: 2560)
        guard let jpeg = resized.jpegData(compressionQuality: 0.85) else { return nil }
        let metadata = MediaMetadata(width: Int(resized.size.width * resized.scale),
                                     height: Int(resized.size.height * resized.scale),
                                     durationSeconds: nil,
                                     takenAt: exifDate(data))
        return (jpeg, metadata)
    }

    /// A centered square JPEG (512 px) for a profile photo.
    static func prepareAvatar(_ data: Data, side: CGFloat = 512) -> Data? {
        guard let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 else { return nil }
        let scale = side / min(image.size.width, image.size.height)
        let drawn = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let square = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
            image.draw(in: CGRect(x: (side - drawn.width) / 2, y: (side - drawn.height) / 2,
                                  width: drawn.width, height: drawn.height))
        }
        return square.jpegData(compressionQuality: 0.85)
    }

    static func videoMetadata(_ data: Data, fileExtension: String) async -> MediaMetadata {
        var metadata = MediaMetadata()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(fileExtension)
        do {
            try data.write(to: url)
            defer { try? FileManager.default.removeItem(at: url) }
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            let seconds = CMTimeGetSeconds(duration)
            if seconds.isFinite { metadata.durationSeconds = (seconds * 10).rounded() / 10 }
            if let track = try await asset.loadTracks(withMediaType: .video).first {
                let (size, transform) = try await track.load(.naturalSize, .preferredTransform)
                let rect = CGRect(origin: .zero, size: size).applying(transform)
                metadata.width = Int(abs(rect.width))
                metadata.height = Int(abs(rect.height))
            }
            if let item = try await asset.load(.creationDate) {
                metadata.takenAt = try await item.load(.dateValue)
            }
        } catch {
            print("homeOS video metadata:", error)
        }
        return metadata
    }

    /// EXIF DateTimeOriginal ("yyyy:MM:dd HH:mm:ss", local time) if present.
    static func exifDate(_ data: Data) -> Date? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any],
              let raw = exif[kCGImagePropertyExifDateTimeOriginal as String] as? String else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: raw)
    }

    static func durationLabel(_ seconds: Double?) -> String? {
        guard let seconds, seconds.isFinite, seconds > 0 else { return nil }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
