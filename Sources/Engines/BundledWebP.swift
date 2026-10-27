import CoreGraphics
import Darwin
import Foundation

/// Load only our bundled encoder; never search arbitrary dylib paths at runtime.
enum BundledWebP {
    private typealias Encode = @convention(c) (UnsafePointer<UInt8>?, Int32, Int32, Int32, Float, UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?) -> Int
    private typealias Free = @convention(c) (UnsafeMutableRawPointer?) -> Void
    private struct Library {
        let handle: UnsafeMutableRawPointer
        let encode: Encode
        let free: Free
    }
    private static let library: Library? = {
        let url: URL?
        if Bundle.main.bundleURL.pathExtension == "app" {
            url = Bundle.main.url(forResource: "libyuzuwebp", withExtension: "dylib")
        } else {
            // Brisk's direct test runner is an executable outside an app bundle.
            url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/native/libyuzuwebp.dylib")
        }
        guard let url, let handle = dlopen(url.path, RTLD_NOW | RTLD_LOCAL) else { return nil }
        guard let encode = dlsym(handle, "WebPEncodeRGBA"), let free = dlsym(handle, "WebPFree") else { dlclose(handle); return nil }
        return Library(handle: handle, encode: unsafeBitCast(encode, to: Encode.self), free: unsafeBitCast(free, to: Free.self))
    }()

    static var isAvailable: Bool { library != nil }
    static var animationHandle: UnsafeMutableRawPointer? { library?.handle }

    static func write(_ image: CGImage, to url: URL, quality: Double) throws {
        try Task.checkCancellation()
        guard let library else { throw YuzuError.invalidInput("The bundled WebP encoder could not load. Reinstall Yuzu or choose another format.") }
        guard image.width <= 16383, image.height <= 16383, image.width * image.height <= 100_000_000 else {
            throw YuzuError.invalidInput("This image exceeds the WebP size limit. Resize it first.")
        }
        let stride = image.width * 4
        var rgba = [UInt8](repeating: 0, count: stride * image.height)
        let count = try rgba.withUnsafeMutableBytes { bytes -> Int in
            guard
                let context = CGContext(
                    data: bytes.baseAddress, width: image.width, height: image.height,
                    bitsPerComponent: 8, bytesPerRow: stride, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            else { throw YuzuError.encodeFailed("WebP pixel buffer") }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            let pixels = bytes.bindMemory(to: UInt8.self)
            // Core Graphics supplies premultiplied RGBA; libwebp expects straight RGBA.
            for offset in Swift.stride(from: 0, to: pixels.count, by: 4) {
                if offset % (stride * 64) == 0 { try Task.checkCancellation() }
                let alpha = Int(pixels[offset + 3])
                if alpha > 0 && alpha < 255 {
                    for channel in 0..<3 { pixels[offset + channel] = UInt8(min(255, (Int(pixels[offset + channel]) * 255 + alpha / 2) / alpha)) }
                }
            }
            var output: UnsafeMutablePointer<UInt8>?
            let size = library.encode(pixels.baseAddress, Int32(image.width), Int32(image.height), Int32(stride), Float(min(1, max(0, quality)) * 100), &output)
            guard size > 0, let output else { throw YuzuError.encodeFailed("WebP") }
            defer { library.free(output) }
            try Task.checkCancellation()
            try Data(bytes: output, count: size).write(to: url)
            return size
        }
        DiagnosticLog.log("bundled WebP encoded \(count) bytes")
    }
}
