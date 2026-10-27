import AVFoundation
import Foundation
import ImageIO

/// A conservative, immutable snapshot. Missing or unprobed backends never imply support.
struct BackendCapabilities: Equatable {
    var bundledWebPAvailable = BundledWebP.isAvailable
    var ffmpegPath: String?
    var encoders: Set<String> = []
    var decoders: Set<String> = []
    var muxers: Set<String> = []
    var filters: Set<String> = []
    var cwebpPath: String?
    var officeAvailable = false
    var failure: String?

    static func names(in listing: String, flagCount: Int) -> Set<String> {
        Set(
            listing.split(separator: "\n").flatMap { line -> [String] in
                let parts = line.split(whereSeparator: \.isWhitespace)
                guard parts.count >= 2, parts[0].count == flagCount,
                    parts[0].allSatisfy({ $0 == "." || $0.isUppercase }), parts[1] != "="
                else { return [] }
                return parts[1].split(separator: ",").map(String.init)
            })
    }

    func canEncodeImage(_ format: FileFormat) -> Bool {
        if format == .ico || format == .icns { return true }
        if ImageIOBridge.canEncodeNatively(format) { return true }
        if format == .webp, bundledWebPAvailable { return true }
        if format == .webp, cwebpPath != nil { return true }
        guard ffmpegPath != nil, decoders.contains("png") else { return false }
        switch format {
        case .webp: return encoders.contains("libwebp") && muxers.contains("webp")
        case .avif: return encoders.contains("libaom-av1") && muxers.contains("avif")
        // A raw HEVC stream is not a HEIC container. Only ImageIO may write HEIC.
        default: return false
        }
    }

    func supports(from source: FileFormat, to target: FileFormat) -> Bool {
        if source.category == .archive { return false }  // Archive operations belong to Actions.
        if OfficeEngine().supports(from: source, to: target) { return officeAvailable }
        if source.category == .image {
            guard source == .svg || source.utType.map({ ImageIOBridge.nativeDecoders.contains($0.identifier) }) == true else { return false }
            return target == .pdf || target == .docx || canEncodeImage(target)
        }
        if source.category == .audio || source.category == .video {
            let nativeInputs: Set<FileFormat> = [.mp3, .m4a, .wav, .aiff, .flac, .mp4, .mov]
            let nativeType = source.utType.map { AVURLAsset.audiovisualTypes().contains(AVFileType(rawValue: $0.identifier)) } == true
            if target == .webp, NativeWebPAnimation.isAvailable, source == .gif || nativeInputs.contains(source) && nativeType { return true }
            if nativeInputs.contains(source), nativeType,
                (source.category == .audio ? AudioEngine.nativeTargets.contains(target) : VideoEngine.nativeTargets.contains(target))
            {
                return true
            }
            return canDecodeMedia(source) && canEncodeMedia(target)
        }
        return Engines.engine(from: source, to: target) != nil
    }

    func canDecodeMedia(_ format: FileFormat) -> Bool {
        guard ffmpegPath != nil else { return false }
        let required: Set<String>
        switch format {
        case .mp3: required = ["mp3", "mp3float"]
        case .m4a: required = ["aac"]
        case .wav: required = ["pcm_s16le"]
        case .aiff: required = ["pcm_s16be"]
        case .flac: required = ["flac"]
        case .ogg: required = ["vorbis"]
        case .opus: required = ["opus", "libopus"]
        case .wma: required = ["wmav2"]
        case .gif: required = ["gif"]
        case .webm: required = ["vp8", "vp9", "libvpx-vp9"]
        case .wmv: required = ["wmv2", "wmv3", "vc1"]
        case .avi: required = ["mpeg4", "h264"]
        default: required = ["h264", "hevc"]
        }
        return !required.isDisjoint(with: decoders)
    }

    func canEncodeMedia(_ target: FileFormat) -> Bool {
        if target == .webp {
            return ffmpegPath != nil && encoders.contains("libwebp_anim") && muxers.contains("webp") && Set(["fps", "scale"]).isSubset(of: filters)
        }
        let arguments =
            target.category == .audio
            ? AudioEngine.codecArguments(for: target) + AudioEngine.containerArguments(for: target) : VideoEngine.codecArguments(for: target)
        if target == .gif {
            return ffmpegPath != nil && encoders.contains("gif") && muxers.contains("gif")
                && Set(["fps", "scale", "split", "palettegen", "paletteuse"]).isSubset(of: filters)
        }
        guard ffmpegPath != nil, !arguments.isEmpty else { return false }
        for index in arguments.indices where ["-c:a", "-c:v", "-f"].contains(arguments[index]) && index + 1 < arguments.count {
            let available = arguments[index] == "-f" ? muxers : encoders
            if !available.contains(arguments[index + 1]) { return false }
        }
        return true
    }

    func supports(tool: ToolID, formats: [FileFormat]) -> Bool {
        guard tool.applies(to: formats) else { return false }
        if tool == .fileComparison { return true }
        if tool == .audioChannels {
            return filters.contains("pan") && formats.allSatisfy { canDecodeMedia($0) && canEncodeMedia($0) }
        }
        if tool == .audioToVideo {
            return formats.allSatisfy(canDecodeMedia) && canEncodeMedia(.mp4)
                && Set(["showwaves", "showfreqs", "color", "scale"]).isSubset(of: filters)
        }
        for format in formats {
            if format.category == .image {
                guard format == .svg || format.utType.map({ ImageIOBridge.nativeDecoders.contains($0.identifier) }) == true else { return false }
            } else if format.category == .audio || format.category == .video {
                if format == .gif { return tool == .editMetadata && ImageIOBridge.canEncodeNatively(.gif) }
                let native: Set<FileFormat> = [.mp3, .m4a, .wav, .aiff, .flac, .mp4, .mov]
                if !native.contains(format), !(canDecodeMedia(format) && canEncodeMedia(format)) { return false }
            }
        }
        return true
    }
}

enum RuntimeCapabilities {
    private static let lock = NSLock()
    private static var value = BackendCapabilities()
    static var snapshot: BackendCapabilities { lock.withLock { value } }
    static let didChange = Notification.Name("YuzuBackendCapabilitiesChanged")

    static func refresh() async -> BackendCapabilities {
        let result = await BackendProbe.shared.refresh()
        guard !Task.isCancelled else { return snapshot }
        let changed = lock.withLock { () -> Bool in
            guard value != result else { return false }
            value = result
            return true
        }
        if changed { await MainActor.run { NotificationCenter.default.post(name: didChange, object: nil) } }
        return result
    }
}

actor BackendProbe {
    static let shared = BackendProbe()
    private var key: String?
    private var cached = BackendCapabilities()

    func refresh() async -> BackendCapabilities {
        let ffmpeg = FFmpeg.path
        let cwebp = ValidationRuntime.nativeOnly ? nil : Shell.which("cwebp")
        let office = OfficeEngine.executable
        let identity = [ffmpeg, cwebp, office].map { path -> String in
            guard let path else { return "missing" }
            let attrs = try? FileManager.default.attributesOfItem(atPath: path)
            return "\(path):\(attrs?[.modificationDate] ?? ""): \(attrs?[.size] ?? "")"
        }.joined(separator: "|")
        if key == identity { return cached }
        var result = BackendCapabilities(officeAvailable: office != nil)
        if let ffmpeg {
            do {
                let encoder = try await Shell.run(ffmpeg, ["-hide_banner", "-encoders"], outputLimit: 2_000_000)
                let decoder = try await Shell.run(ffmpeg, ["-hide_banner", "-decoders"], outputLimit: 2_000_000)
                let muxer = try await Shell.run(ffmpeg, ["-hide_banner", "-muxers"], outputLimit: 2_000_000)
                let filter = try await Shell.run(ffmpeg, ["-hide_banner", "-filters"], outputLimit: 2_000_000)
                if encoder.succeeded && decoder.succeeded && muxer.succeeded && filter.succeeded {
                    result.ffmpegPath = ffmpeg
                    result.encoders = BackendCapabilities.names(in: encoder.stdout, flagCount: 6)
                    result.decoders = BackendCapabilities.names(in: decoder.stdout, flagCount: 6)
                    result.muxers = BackendCapabilities.names(in: muxer.stdout, flagCount: 1)
                    result.filters = BackendCapabilities.names(in: filter.stdout, flagCount: 3)
                } else {
                    result.failure = FFmpeg.summarize(encoder.stderr + decoder.stderr + muxer.stderr + filter.stderr)
                }
            } catch { result.failure = error.localizedDescription }
        }
        if let cwebp, let version = try? await Shell.run(cwebp, ["-version"], outputLimit: 4096), version.succeeded {
            result.cwebpPath = cwebp
        }
        // Do not poison the cache when a caller cancelled a probe.
        if !Task.isCancelled { cached = result; key = identity }
        return result
    }
}
