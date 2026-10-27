import AVFoundation
import Foundation

enum Compressor {
    static func compress(
        _ url: URL, preset: CompressionPreset, resizeLongEdge: Int, targetBytes: Int64?, to destination: URL, progress: @escaping (Double) -> Void
    ) async throws {
        if let targetBytes, targetBytes <= 0 { throw YuzuError.invalidInput("Choose a target size greater than zero.") }
        let output = outputFormat(for: url)
        try await OutputTransaction.write(source: url, destination: destination, format: output) { staged in
            try await compressUnstaged(url, preset: preset, resizeLongEdge: resizeLongEdge, targetBytes: targetBytes, to: staged, progress: progress)
        }
    }

    private static func compressUnstaged(
        _ url: URL, preset: CompressionPreset, resizeLongEdge: Int, targetBytes: Int64?, to destination: URL, progress: @escaping (Double) -> Void
    ) async throws {
        guard let format = FileFormat.detect(url) else { throw YuzuError.unreadable(url) }
        switch format.category {
        case .image:
            try await compressImage(
                url, format: format, preset: preset, resizeLongEdge: resizeLongEdge, targetBytes: targetBytes, to: destination, progress: progress)
        case .video:
            try await VideoOps.compress(url, preset: preset, targetBytes: targetBytes, to: destination, progress: progress)
        case .audio:
            try await compressAudio(url, format: format, preset: preset, targetBytes: targetBytes, to: destination, progress: progress)
        case .document where format == .pdf:
            try PDFOps.compress(url, strong: preset == .strong, to: destination)
            progress(1)
        default:
            throw YuzuError.invalidInput("\(format.displayName) files can't be compressed. Convert to ZIP instead.")
        }
    }

    static func outputFormat(for url: URL) -> FileFormat {
        guard let format = FileFormat.detect(url) else { return .jpg }
        switch format.category {
        case .image:
            switch format {
            case .png: return .png  // Keep transparency and make the advertised extension deterministic.
            case .bmp, .tiff, .svg: return .jpg
            case .avif, .webp: return RuntimeCapabilities.snapshot.canEncodeImage(format) ? format : .jpg
            default: return format
            }
        case .video:
            return VideoEngine.nativeTargets.contains(format) ? format : (FFmpeg.isAvailable ? format : .mp4)
        case .audio:
            return format == .mp3 && FFmpeg.isAvailable ? .mp3 : .m4a
        default:
            return format
        }
    }

    static func compressImage(
        _ url: URL, format: FileFormat, preset: CompressionPreset, resizeLongEdge: Int, targetBytes: Int64?, to destination: URL,
        progress: @escaping (Double) -> Void
    ) async throws {
        var image = try ImageIOBridge.load(url)
        if resizeLongEdge > 0 { image = ImageIOBridge.resized(image, longEdge: resizeLongEdge) }
        let output = outputFormat(for: url)
        let finalFormat = output
        progress(0.2)

        guard let targetBytes else {
            if finalFormat == .png {
                let scaled = preset == .strong ? ImageIOBridge.resized(image, longEdge: Int(Double(max(image.width, image.height)) * 0.7)) : image
                try ImageIOBridge.write(scaled, to: destination, format: .png)
            } else {
                try await ImageIOBridge.writeAnyFormat(image, to: destination, format: finalFormat, quality: preset.imageQuality)
            }
            progress(1)
            return
        }

        if finalFormat == .png {
            for attempt in 0..<20 {
                try Task.checkCancellation()
                try ImageIOBridge.write(image, to: destination, format: .png)
                progress(0.2 + 0.7 * Double(attempt + 1) / 20)
                if FileSizeFormatter.size(of: destination) <= targetBytes { progress(1); return }
                guard max(image.width, image.height) > 1 else { break }
                image = ImageIOBridge.scaled(image, to: CGSize(width: max(1, Double(image.width) * 0.75), height: max(1, Double(image.height) * 0.75)))
            }
            throw YuzuError.invalidInput("The target size is too small for a valid PNG. Choose a larger size.")
        }

        var low = 0.15, high = 0.95
        var candidate = image
        var attempts = 0
        var best: Double?
        while attempts < 12 {
            try Task.checkCancellation()
            attempts += 1
            let quality = (low + high) / 2
            try await ImageIOBridge.writeAnyFormat(candidate, to: destination, format: finalFormat, quality: quality)
            let size = FileSizeFormatter.size(of: destination)
            progress(0.2 + 0.7 * Double(attempts) / 12)
            if size <= targetBytes {
                best = quality
                low = quality
                if Double(size) > Double(targetBytes) * 0.9 { break }
            } else {
                high = quality
            }
            if high - low < 0.03 {
                if best == nil {
                    let shrink = 0.8
                    candidate = ImageIOBridge.scaled(candidate, to: CGSize(width: Double(candidate.width) * shrink, height: Double(candidate.height) * shrink))
                    low = 0.15
                    high = 0.95
                    guard candidate.width > 64 else { break }
                } else {
                    break
                }
            }
        }
        if let best {
            try await ImageIOBridge.writeAnyFormat(candidate, to: destination, format: finalFormat, quality: best)
        }
        guard FileSizeFormatter.size(of: destination) <= targetBytes else {
            throw YuzuError.invalidInput("The target size could not be reached. Choose a larger size.")
        }
        progress(1)
    }

    static func compressAudio(
        _ url: URL, format: FileFormat, preset: CompressionPreset, targetBytes: Int64?, to destination: URL, progress: @escaping (Double) -> Void
    ) async throws {
        let info = await MediaInfo.load(url)
        var bitrate = preset.audioBitrate
        if let targetBytes, info.duration > 0 {
            bitrate = max(32_000, min(320_000, Int(Double(targetBytes) * 8 * 0.96 / info.duration)))
        }
        let output = outputFormat(for: url)
        if output == .m4a, await MediaInfo.isNativelyReadable(url), !FFmpeg.isAvailable || targetBytes == nil {
            try await AVExporter.export(asset: AVURLAsset(url: url), to: destination, format: .m4a, preset: AVAssetExportPresetAppleM4A, progress: progress)
            return
        }
        try await AudioEngine.ffmpegConvert(source: url, destination: destination, target: output, bitrate: bitrate, progress: progress)
    }
}
