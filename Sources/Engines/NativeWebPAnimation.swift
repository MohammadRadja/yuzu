import AVFoundation
import Darwin
import Foundation
import ImageIO

enum NativeWebPAnimation {
    private typealias New = @convention(c) (Int32, Int32) -> OpaquePointer?
    private typealias Add = @convention(c) (OpaquePointer?, UnsafePointer<UInt8>?, Int32, Int32, Int32, Float) -> Int32
    private typealias Finish = @convention(c) (OpaquePointer?, Int32, UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?) -> Int
    private typealias Delete = @convention(c) (OpaquePointer?) -> Void
    private typealias Free = @convention(c) (UnsafeMutableRawPointer?) -> Void
    private typealias Cancelled = @convention(c) () -> Int32
    private typealias Validate = @convention(c) (UnsafePointer<UInt8>?, Int, Cancelled?) -> Int32
    private struct API {
        let new: New; let add: Add; let finish: Finish; let delete: Delete; let free: Free; let validate: Validate
    }
    private static let api: API? = {
        guard let handle = BundledWebP.animationHandle,
            let new = dlsym(handle, "YuzuWebPAnimationNew"), let add = dlsym(handle, "YuzuWebPAnimationAdd"),
            let finish = dlsym(handle, "YuzuWebPAnimationFinish"), let delete = dlsym(handle, "YuzuWebPAnimationDelete"),
            let free = dlsym(handle, "WebPFree"), let validate = dlsym(handle, "YuzuWebPValidate")
        else { return nil }
        return API(
            new: unsafeBitCast(new, to: New.self), add: unsafeBitCast(add, to: Add.self), finish: unsafeBitCast(finish, to: Finish.self),
            delete: unsafeBitCast(delete, to: Delete.self), free: unsafeBitCast(free, to: Free.self), validate: unsafeBitCast(validate, to: Validate.self))
    }()
    static var isAvailable: Bool { api != nil }
    static func validate(_ url: URL) throws -> Bool {
        guard let api, FileSizeFormatter.size(of: url) <= 256 * 1_024 * 1_024 else { return false }
        let bytes = try Data(contentsOf: url, options: .mappedIfSafe)
        let cancelled: Cancelled = { Task.isCancelled ? 1 : 0 }
        return bytes.withUnsafeBytes { api.validate($0.bindMemory(to: UInt8.self).baseAddress, $0.count, cancelled) == 1 }
    }
    static func convert(_ source: URL, to destination: URL, progress: @escaping (Double) -> Void) async throws {
        guard let api else { throw YuzuError.invalidInput("The bundled WebP animation encoder is unavailable.") }
        let gif = FileFormat.detect(source) == .gif ? CGImageSourceCreateWithURL(source as CFURL, nil) : nil
        let generator: AVAssetImageGenerator?
        let count: Int
        let duration: Double
        let first: CGImage
        if let gif {
            count = CGImageSourceGetCount(gif)
            duration = 0
            generator = nil
            guard let frame = CGImageSourceCreateImageAtIndex(gif, 0, nil) else { throw YuzuError.unreadable(source) }
            first = frame
        } else {
            let asset = AVURLAsset(url: source)
            duration = try await asset.load(.duration).seconds
            guard duration.isFinite, duration > 0, duration <= 400 else {
                throw YuzuError.invalidInput("Animated WebP supports videos up to 400 seconds. Trim the video first.")
            }
            count = max(1, Int(ceil(duration * 12)))
            let imageGenerator = AVAssetImageGenerator(asset: asset)
            imageGenerator.appliesPreferredTrackTransform = true
            imageGenerator.maximumSize = CGSize(width: 640, height: 640)
            imageGenerator.requestedTimeToleranceBefore = .zero
            imageGenerator.requestedTimeToleranceAfter = .zero
            generator = imageGenerator
            first = try await imageGenerator.image(at: .zero).image
        }
        guard (1...5000).contains(count) else { throw YuzuError.invalidInput("Animated WebP supports up to 5,000 frames.") }
        let scale = min(1, 640 / CGFloat(max(first.width, first.height)))
        let width = max(1, Int(CGFloat(first.width) * scale)), height = max(1, Int(CGFloat(first.height) * scale))
        guard let encoder = api.new(Int32(width), Int32(height)) else { throw YuzuError.encodeFailed("WebP animation") }
        defer { api.delete(encoder); generator?.cancelAllCGImageGeneration() }
        var timestamp = 0
        for index in 0..<count {
            try Task.checkCancellation()
            let image: CGImage
            var delay = 83
            if let gif {
                guard let frame = CGImageSourceCreateImageAtIndex(gif, index, nil) else { throw YuzuError.unreadable(source) }
                image = frame
                let props = CGImageSourceCopyPropertiesAtIndex(gif, index, nil) as? [CFString: Any]
                let timing = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
                let seconds = (timing?[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? (timing?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
                guard seconds.isFinite, seconds >= 0, seconds <= 60 else { throw YuzuError.invalidInput("Unsupported GIF frame timing.") }
                delay = max(20, Int(seconds * 1000))
            } else if let generator {
                image = index == 0 ? first : try await generator.image(at: CMTime(seconds: Double(index) / 12, preferredTimescale: 600)).image
                delay = max(1, Int(min(duration, Double(index + 1) / 12) * 1000) - timestamp)
            } else {
                throw YuzuError.unreadable(source)
            }
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            let success = try pixels.withUnsafeMutableBytes { bytes -> Bool in
                guard
                    let context = CGContext(
                        data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
                else { throw YuzuError.encodeFailed("animation pixels") }
                context.interpolationQuality = .high
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                let data = bytes.bindMemory(to: UInt8.self)
                for offset in stride(from: 0, to: data.count, by: 4) {
                    let alpha = Int(data[offset + 3])
                    if alpha > 0 && alpha < 255 { for channel in 0..<3 { data[offset + channel] = UInt8(min(255, Int(data[offset + channel]) * 255 / alpha)) } }
                }
                return api.add(encoder, data.baseAddress, Int32(width), Int32(height), Int32(timestamp), 85) == 1
            }
            guard success else { throw YuzuError.encodeFailed("WebP frame \(index + 1)") }
            timestamp += delay
            progress(Double(index + 1) / Double(count + 1))
        }
        var bytes: UnsafeMutablePointer<UInt8>?
        let size = api.finish(encoder, Int32(timestamp), &bytes)
        guard size > 0, let bytes else { throw YuzuError.encodeFailed("WebP animation") }
        defer { api.free(bytes) }
        try Task.checkCancellation()
        try Data(bytes: bytes, count: size).write(to: destination)
        let valid = try validate(destination)
        try Task.checkCancellation()
        guard valid else { throw YuzuError.encodeFailed("WebP animation validation") }
        progress(1)
    }
}
