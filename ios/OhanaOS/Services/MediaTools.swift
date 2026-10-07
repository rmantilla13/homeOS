import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreMedia
import ImageIO
import Supabase
import SwiftUI
import UIKit
import UniformTypeIdentifiers

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

    /// A small square-ish preview. A poster or photo is downloaded and
    /// downscaled; a video without a poster gives a frame from the file.
    func thumbnail(for item: MediaItem, url: URL, isPoster: Bool = false) async -> UIImage? {
        let key = item.storagePath as NSString
        if let image = thumbnails.object(forKey: key) { return image }
        let image = (isPoster || !item.isVideo)
            ? await MediaTools.downloadImage(url: url, maxPixel: 480)
            : await MediaTools.videoFrame(url: url, maxPixel: 480)
        if let image { keep(image, for: item.storagePath) }
        return image
    }

    /// The grid preview: the uploaded poster when the row has one, else the
    /// file itself (rows from before posters, or a poster that's missing).
    func thumbnail(for item: MediaItem, store: FamilyStore) async -> UIImage? {
        if let image = cachedThumbnail(for: item) { return image }
        if let poster = await store.posterURL(for: item),
           let image = await thumbnail(for: item, url: poster, isPoster: true) {
            return image
        }
        guard let url = await store.signedURL(for: item) else { return nil }
        return await thumbnail(for: item, url: url)
    }

    /// Keeps the poster that was just uploaded, so the new tile shows at once.
    func remember(_ jpeg: Data, for storagePath: String) {
        guard let image = UIImage(data: jpeg) else { return }
        keep(MediaTools.downscale(image, maxPixel: 480), for: storagePath)
    }

    private func keep(_ image: UIImage, for storagePath: String) {
        thumbnails.setObject(image, forKey: storagePath as NSString)
        if tints[storagePath] == nil, let color = MediaTools.averageColor(of: image) {
            tints[storagePath] = color
        }
    }

    /// A screen-sized photo for the viewer.
    func fullImage(for item: MediaItem, url: URL) async -> UIImage? {
        let key = item.storagePath as NSString
        if let image = fullImages.object(forKey: key) { return image }
        let image = await MediaTools.downloadImage(url: url, maxPixel: 2048)
        if let image { fullImages.setObject(image, forKey: key) }
        return image
    }

    #if DEBUG
    /// Demo mode: an image drawn on the phone stands in for the download,
    /// for the grid tile and the viewer's backdrop color.
    func seedThumbnail(_ image: UIImage, for item: MediaItem) {
        thumbnails.setObject(image, forKey: item.storagePath as NSString)
        tints[item.storagePath] = MediaTools.averageColor(of: image)
    }
    #endif
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

    /// Redraws upright at most `maxPixel` on the long side. A small image
    /// that isn't upright is redrawn too: its JPEG would otherwise keep the
    /// pixels sideways with an EXIF orientation, which the wall ignores.
    static func downscale(_ image: UIImage, maxPixel: CGFloat) -> UIImage {
        let size = image.size
        let scale = min(1, maxPixel / max(size.width, size.height, 1))
        guard scale < 1 || image.imageOrientation != .up else { return image }
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    /// The photo's average color via CIAreaAverage, used to tint the viewer.
    static func averageColor(of image: UIImage) -> Color? {
        guard let rgb = averageRGB(of: image) else { return nil }
        return Color(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue, opacity: 1)
    }

    /// How bright the image is on average, 0...1 (Rec. 709 weights).
    static func averageLuminance(of image: UIImage) -> Double? {
        guard let rgb = averageRGB(of: image) else { return nil }
        return 0.2126 * rgb.red + 0.7152 * rgb.green + 0.0722 * rgb.blue
    }

    private static func averageRGB(of image: UIImage) -> (red: Double, green: Double, blue: Double)? {
        guard let input = CIImage(image: image) else { return nil }
        let filter = CIFilter.areaAverage()
        filter.inputImage = input
        filter.extent = input.extent
        guard let output = filter.outputImage else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        ciContext.render(output, toBitmap: &pixel, rowBytes: 4,
                         bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        return (Double(pixel[0]) / 255, Double(pixel[1]) / 255, Double(pixel[2]) / 255)
    }

    // MARK: Preparing uploads

    /// The largest poster the media service signs (THUMB_MAX_BYTES in the admin app).
    static let posterMaxBytes = 256 * 1024

    /// Photos are re-encoded as JPEG (≤ 2560 px) so the wall display can always
    /// decode them; HEIC isn't reliably supported there. Keeps EXIF capture date.
    static func preparePhoto(_ data: Data) -> (data: Data, metadata: MediaMetadata)? {
        guard let image = UIImage(data: data) else { return nil }
        let resized = downscale(image, maxPixel: 2560)
        guard let jpeg = resized.jpegData(compressionQuality: 0.85) else { return nil }
        let metadata = MediaMetadata(width: Int(resized.size.width * resized.scale),
                                     height: Int(resized.size.height * resized.scale),
                                     durationSeconds: nil,
                                     takenAt: exifDate(data),
                                     thumbnail: posterData(from: resized, maxPixel: 480))
        return (jpeg, metadata)
    }

    /// `preparePhoto` away from the main actor; decoding and encoding take a moment.
    static func preparePhotoAsync(_ data: Data) async -> (data: Data, metadata: MediaMetadata)? {
        preparePhoto(data)
    }

    /// A JPEG poster for the grid, the wall's tiles and the admin console:
    /// at most `maxPixel` on the long side and at most `posterMaxBytes`.
    /// Steps the quality down, then the size (to 640 px), before giving up.
    static func posterData(from image: UIImage, maxPixel: CGFloat) -> Data? {
        var sides = [maxPixel]
        if maxPixel > 640 { sides.append(640) }
        for side in sides {
            let small = downscale(image, maxPixel: side)
            for quality in [0.7, 0.55, 0.4] as [CGFloat] {
                if let jpeg = small.jpegData(compressionQuality: quality), !jpeg.isEmpty, jpeg.count <= posterMaxBytes {
                    return jpeg
                }
            }
        }
        return nil
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

    /// A movie copied out of the photo picker. The picker deletes its own
    /// temp file when `importing` returns, so this keeps a hard link (or a
    /// copy) the upload can stream from. Delete `url` when the upload ends.
    struct PickedVideo: Transferable {
        let url: URL

        static var transferRepresentation: some TransferRepresentation {
            FileRepresentation(contentType: .movie) { video in
                SentTransferredFile(video.url)
            } importing: { received in
                let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
                let dest = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension(ext)
                do {
                    try FileManager.default.linkItem(at: received.file, to: dest)
                } catch {
                    try FileManager.default.copyItem(at: received.file, to: dest)
                }
                return PickedVideo(url: dest)
            }
        }
    }

    /// Duration, size and creation date, read from the file without loading it.
    /// No poster: that comes from the file actually uploaded (`posterJPEG`).
    static func videoMetadata(at url: URL) async -> MediaMetadata {
        var metadata = MediaMetadata()
        do {
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
            print("OhanaOS video metadata:", error)
        }
        return metadata
    }

    // MARK: Preparing videos

    /// Why a video couldn't be prepared. `interrupted`: iOS stopped the export
    /// because Ohana left the screen. That item isn't retried another way.
    enum VideoPrepError: Error {
        case noVideoTrack, presetUnavailable, exportFailed, interrupted
    }

    /// What a video file holds, read from its headers without decoding it.
    struct VideoProbe: Sendable {
        var codec: FourCharCode?
        var displaySize: CGSize
        var frameRate: Float
        var bitsPerSecond: Double
        var isHDR: Bool
        var bitDepth: Int?
        var transfer: String?
        var durationSeconds: Double
        var fileBytes: Int

        var longSide: CGFloat { max(displaySize.width, displaySize.height) }
    }

    enum VideoPlan: Equatable, Sendable {
        case asIs, remux, transcode(toSDR: Bool, capFrameRate: Bool)
    }

    /// The file to upload (a temp file the caller deletes) and its row's facts.
    struct PreparedVideo: Sendable {
        let url: URL
        let fileExtension: String
        var metadata: MediaMetadata
    }

    /// The wall panel is 1920×1200: more pixels are only more bytes to send.
    static let wallMaxLongSide: CGFloat = 1920
    /// An iPhone's own 1080p30 is about 6–12 Mb/s. Above this, shrinking pays.
    static let passthroughMaxBitsPerSecond = 16_000_000.0
    /// 30 fps, with room for 29.97 and variable frame rates.
    static let maxFrameRate: Float = 31

    static func probeVideo(at url: URL) async throws -> VideoProbe {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw VideoPrepError.noVideoTrack
        }
        // Two loads of three: the longer overloads differ between SDKs.
        let (naturalSize, transform, frameRate) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate)
        let (dataRate, formats, characteristics) = try await track.load(.estimatedDataRate, .formatDescriptions,
                                                                        .mediaCharacteristics)
        var shown = CGRect(origin: .zero, size: naturalSize).applying(transform).size
        if !shown.width.isFinite || !shown.height.isFinite { shown = .zero }  // Int() of these would trap
        let format = formats.first
        let transfer = format?.extensions[.transferFunction]?.propertyListRepresentation as? String
        let bitDepth = format?.extensions[.bitsPerComponent]?.propertyListRepresentation as? Int
        let hdrTransfers: [CMFormatDescription.Extensions.Value.TransferFunction] = [.itu_R_2100_HLG, .smpte_ST_2084_PQ]
        var isHDR = characteristics.contains(.containsHDRVideo)
        if let transfer, hdrTransfers.contains(where: { ($0.rawValue as String) == transfer }) { isHDR = true }
        let seconds = duration.seconds.isFinite ? max(0, duration.seconds) : 0
        let bytes = fileSize(url)
        let bitsPerSecond = dataRate > 0 ? Double(dataRate) : (seconds > 0 ? Double(bytes) * 8 / seconds : 0)
        return VideoProbe(codec: format?.mediaSubType.rawValue,
                          displaySize: CGSize(width: abs(shown.width), height: abs(shown.height)),
                          frameRate: frameRate, bitsPerSecond: bitsPerSecond, isHDR: isHDR, bitDepth: bitDepth,
                          transfer: transfer, durationSeconds: seconds, fileBytes: bytes)
    }

    /// The Pi plays it well as it is: HEVC (its decoder block) or H.264 (on
    /// the CPU, fine at 1080p), 8-bit SDR, at most 1920 px and 31 fps.
    static func playsOnWall(_ video: VideoProbe) -> Bool {
        let codecs = [CMFormatDescription.MediaSubType.hevc.rawValue, CMFormatDescription.MediaSubType.h264.rawValue]
        guard let codec = video.codec, codecs.contains(codec) else { return false }
        return !video.isHDR && (video.bitDepth ?? 8) <= 8
            && video.longSide <= wallMaxLongSide && video.frameRate <= maxFrameRate
    }

    static func plan(for video: VideoProbe, fileURL: URL) -> VideoPlan {
        let ready = playsOnWall(video) && video.bitsPerSecond <= passthroughMaxBitsPerSecond
            && ["mov", "mp4", "m4v"].contains(fileURL.pathExtension.lowercased())
        guard ready else {
            return .transcode(toSDR: video.isHDR || (video.bitDepth ?? 8) > 8, capFrameRate: video.frameRate > maxFrameRate)
        }
        return isFastStart(fileURL) ? .asIs : .remux
    }

    /// Whether the index (`moov`) comes before the media (`mdat`), so a
    /// player can start before the whole file has arrived.
    static func isFastStart(_ url: URL) -> Bool {
        guard let file = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? file.close() }
        var offset: UInt64 = 0
        for _ in 0..<64 {
            guard (try? file.seek(toOffset: offset)) != nil,
                  let data = try? file.read(upToCount: 16), data.count >= 8 else { return false }
            let header = [UInt8](data)
            var size = header[0..<4].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            let type = String(decoding: header[4..<8], as: UTF8.self)
            if type == "moov" { return true }
            if type == "mdat" { return false }
            if size == 1 {  // the real size follows as 64 bits
                guard header.count >= 16 else { return false }
                size = header[8..<16].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            }
            guard size >= 8 else { return false }  // 0 means "to the end of the file"
            let (next, overflow) = offset.addingReportingOverflow(size)
            if overflow { return false }
            offset = next
        }
        return false
    }

    /// Makes a video right for the wall: at most 1080p and 30 fps, SDR, with
    /// its index first so playback starts at once. Clips that already fit go
    /// as they are. Returns `source` or a new temp file (the caller deletes
    /// both). Throws CancellationError, `.interrupted`, or any other error
    /// when it couldn't be done; the caller then uploads the original.
    static func prepareVideo(_ source: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> PreparedVideo {
        #if DEBUG
        let started = Date()
        #endif
        var metadata = await videoMetadata(at: source)  // the date and duration of the original
        let probe = try await probeVideo(at: source)
        let asset = AVURLAsset(url: source)
        let decision = plan(for: probe, fileURL: source)
        var output = source
        do {
            switch decision {
            case .asIs:
                break
            case .remux:
                output = try await runExport(asset, preset: AVAssetExportPresetPassthrough, as: .mov,
                                             composition: nil, progress: progress)
            case let .transcode(toSDR, capFrameRate):
                output = try await transcode(asset, toSDR: toSDR, capFrameRate: capFrameRate, progress: progress)
                // The presets choose a bitrate from the output size, so a small
                // low-bitrate clip can come out bigger. Then send the source.
                if probe.fileBytes > 0, Double(fileSize(output)) >= 0.9 * Double(probe.fileBytes), playsOnWall(probe) {
                    try? FileManager.default.removeItem(at: output)
                    output = source
                    if !isFastStart(source) {
                        output = try await runExport(asset, preset: AVAssetExportPresetPassthrough, as: .mov,
                                                     composition: nil, progress: progress)
                    }
                }
            }
            try Task.checkCancellation()
        } catch {
            if output != source { try? FileManager.default.removeItem(at: output) }
            throw error
        }

        let result: VideoProbe?
        if output == source {
            result = probe
        } else {
            result = try? await probeVideo(at: output)
            metadata.width = nil  // the original's size no longer applies
            metadata.height = nil
        }
        if let size = result?.displaySize, size.width > 0, size.height > 0 {
            metadata.width = Int(size.width.rounded())
            metadata.height = Int(size.height.rounded())
        }
        // From the file that's uploaded: it's SDR, so the frame looks right.
        metadata.thumbnail = await posterJPEG(for: output, durationSeconds: probe.durationSeconds)
        #if DEBUG
        if let result {
            print("OhanaOS video \(decision): \(fourCC(result.codec)) \(result.bitDepth ?? 8)-bit",
                  result.transfer ?? "-", "\(Int(result.displaySize.width))x\(Int(result.displaySize.height))",
                  String(format: "%.1f fps %.1f Mb/s %ld MB, was %ld MB, %.1f s", result.frameRate,
                         result.bitsPerSecond / 1_000_000, result.fileBytes / 1_000_000,
                         probe.fileBytes / 1_000_000, Date().timeIntervalSince(started)))
        }
        #endif
        let ext = output.pathExtension.isEmpty ? "mov" : output.pathExtension.lowercased()
        metadata.processing = "done"  // right for the wall: the server leaves it alone
        return PreparedVideo(url: output, fileExtension: ext, metadata: metadata)
    }

    /// HEVC 1080p, the codec the Pi 5 decodes in hardware. H.264 1080p when
    /// that fails (some Slo-Mo clips) or keeps HDR: Apple's HEVC presets keep
    /// the source's HDR, the H.264 ones convert to SDR.
    private static func transcode(_ asset: AVURLAsset, toSDR: Bool, capFrameRate: Bool,
                                  progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        var composition: AVMutableVideoComposition?
        if toSDR || capFrameRate {
            let made: AVMutableVideoComposition = try await AVMutableVideoComposition.videoComposition(withPropertiesOf: asset)
            // Render and tag as SDR Rec. 709: what the wall shows correctly.
            made.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
            made.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
            made.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
            if capFrameRate {
                // Apple's documented way to cap the frame rate of an export.
                made.sourceTrackIDForFrameTiming = kCMPersistentTrackID_Invalid
                made.frameDuration = CMTime(value: 1, timescale: 30)
            }
            composition = made
        }
        let hevc: URL
        do {
            hevc = try await runExport(asset, preset: AVAssetExportPresetHEVC1920x1080, as: .mp4,
                                       composition: composition, progress: progress)
        } catch let error where !stopsFallback(error) {
            print("OhanaOS HEVC export failed, trying H.264:", error)
            return try await runExport(asset, preset: AVAssetExportPreset1920x1080, as: .mp4,
                                       composition: composition, progress: progress)
        }
        if let check = try? await probeVideo(at: hevc), check.isHDR {
            try? FileManager.default.removeItem(at: hevc)
            return try await runExport(asset, preset: AVAssetExportPreset1920x1080, as: .mp4,
                                       composition: composition, progress: progress)
        }
        return hevc
    }

    /// Cancelled, or stopped by iOS: neither is worth another way of exporting.
    private static func stopsFallback(_ error: Error) -> Bool {
        error is CancellationError || (error as? VideoPrepError) == .interrupted
    }

    /// One export into a new temp file. Cancelling the task cancels the
    /// export. A failure while Ohana isn't the active app, or AVFoundation's
    /// "operation interrupted", becomes `VideoPrepError.interrupted`.
    private static func runExport(_ asset: AVURLAsset, preset: String, as fileType: AVFileType,
                                  composition: AVVideoComposition?,
                                  progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        try Task.checkCancellation()
        // iOS stops exports in the background, so one started there only
        // fails. Wait instead: the rest of a batch goes on once Ohana is back.
        try await waitUntilActive()
        // An unsupported file type would raise an exception, not an error.
        guard let session = AVAssetExportSession(asset: asset, presetName: preset),
              session.supportedFileTypes.contains(fileType) else {
            throw VideoPrepError.presetUnavailable
        }
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(fileType == .mp4 ? "mp4" : "mov")
        session.outputURL = output
        session.outputFileType = fileType
        session.shouldOptimizeForNetworkUse = true  // index first ("fast start")
        session.metadataItemFilter = .forSharing()  // drops the location; the date was read already
        if let composition { session.videoComposition = composition }

        let running = ExportHandle(session)
        progress(0)
        let poller = Task {
            while !Task.isCancelled {
                progress(Double(running.session.progress))  // not observable; before iOS 18 polling is the way
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        defer { poller.cancel() }
        await withTaskCancellationHandler {
            if running.session.status != .cancelled { await running.session.export() }
        } onCancel: {
            running.session.cancelExport()
        }

        guard session.status == .completed else {
            try? FileManager.default.removeItem(at: output)
            if Task.isCancelled { throw CancellationError() }
            let failure: Error = session.error ?? VideoPrepError.exportFailed
            let active = await appIsActive()
            if !active || isInterruption(failure) { throw VideoPrepError.interrupted }
            throw failure
        }
        progress(1)
        return output
    }

    /// The session isn't Sendable, but reading its progress and cancelling
    /// it from another task is what Apple's own export(to:as:) does too.
    private final class ExportHandle: @unchecked Sendable {
        let session: AVAssetExportSession
        init(_ session: AVAssetExportSession) { self.session = session }
    }

    @MainActor private static func appIsActive() -> Bool {
        UIApplication.shared.applicationState == .active
    }

    /// Returns once Ohana is the active app. Throws CancellationError on
    /// Cancel. Polls: while suspended it costs nothing, and it needs no observer.
    private static func waitUntilActive() async throws {
        var active = await appIsActive()
        while !active {
            try await Task.sleep(for: .milliseconds(500))
            active = await appIsActive()
        }
    }

    private static func isInterruption(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == AVFoundationErrorDomain && error.code == AVError.Code.operationInterrupted.rawValue
    }

    /// A poster from the video: the first of a few early frames that isn't
    /// nearly black (fade-ins), else the first frame found.
    static func posterJPEG(for url: URL, durationSeconds: Double, maxPixel: CGFloat = 960) async -> Data? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        let length = durationSeconds.isFinite ? max(0, durationSeconds) : 0
        var first: UIImage?
        for seconds in [min(1, length * 0.1), min(3, length / 3), 0] {
            guard let frame = try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)) else {
                continue
            }
            let image = UIImage(cgImage: frame.image)
            if (averageLuminance(of: image) ?? 1) > 0.08 { return posterData(from: image, maxPixel: maxPixel) }
            if first == nil { first = image }
        }
        return first.flatMap { posterData(from: $0, maxPixel: maxPixel) }
    }

    /// Video files a crash or a force quit left in tmp (picker copies and
    /// exports). Only ones untouched for a day, in case one is still in use.
    static func removeStaleTempVideos(olderThan age: TimeInterval = 86_400) async {
        let files = FileManager.default
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .attributeModificationDateKey]
        guard let urls = try? files.contentsOfDirectory(at: files.temporaryDirectory,
                                                        includingPropertiesForKeys: Array(keys),
                                                        options: [.skipsHiddenFiles]) else { return }
        let cutoff = Date().addingTimeInterval(-age)
        for url in urls where ["mov", "mp4", "m4v"].contains(url.pathExtension.lowercased()) {
            guard let values = try? url.resourceValues(forKeys: keys) else { continue }
            // A hard-linked picker copy keeps the original's modification
            // date; its attribute date is when the link was made.
            let touched = [values.contentModificationDate, values.attributeModificationDate].compactMap { $0 }.max()
            if let touched, touched < cutoff { try? files.removeItem(at: url) }
        }
    }

    private static func fileSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    #if DEBUG
    private static func fourCC(_ code: FourCharCode?) -> String {
        guard let code else { return "none" }
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        return String(decoding: bytes, as: UTF8.self)
    }
    #endif

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
