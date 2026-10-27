import AVFoundation
import Foundation
import ImageIO
import PDFKit

enum OutputValidator {
    static func validate(_ url: URL, as format: FileFormat) async throws {
        try Task.checkCancellation()
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey, .fileSizeKey])
        guard values.isSymbolicLink != true else { throw invalid(format) }
        if values.isDirectory == true {
            guard [.jpg, .png, .svg].contains(format) else { throw invalid(format) }
            let children = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            guard !children.isEmpty else { throw invalid(format) }
            for child in children {
                guard FileFormat.detect(child) == format else { throw invalid(format) }
                try await validate(child, as: format)
            }
            return
        }
        guard values.isRegularFile == true else { throw invalid(format) }
        if format == .svg {
            let text = try TextFile.read(url)
            guard text.utf8.count <= 64 * 1_024 * 1_024, try DocumentXML.parse(text).elements.first?.name == "svg" else { throw invalid(format) }
            return
        }
        if format.category == .image || format == .gif {
            if format == .webp, try NativeWebPAnimation.validate(url) { return }
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                let actual = CGImageSourceGetType(source) as String?, let expected = format.utType,
                actual == expected.identifier, CGImageSourceGetCount(source) > 0,
                CGImageSourceCreateImageAtIndex(source, 0, nil) != nil,
                CGImageSourceGetStatus(source) == .statusComplete
            else { throw invalid(format) }
            return
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let prefix = try handle.read(upToCount: 512) ?? Data()
        func starts(_ bytes: [UInt8]) -> Bool { prefix.starts(with: bytes) }
        switch format {
        case .json:
            _ = try JSONSerialization.jsonObject(with: Data(contentsOf: url), options: [.fragmentsAllowed])
        case .yaml: _ = try YAMLDocument.read(TextFile.read(url))
        case .xml: _ = try DocumentXML.parse(TextFile.read(url))
        case .pdf:
            guard starts(Array("%PDF-".utf8)), let document = PDFDocument(url: url), document.pageCount > 0 || document.isEncrypted && document.isLocked else {
                throw invalid(format)
            }
        case .docx, .pptx, .xlsx, .ods, .epub, .zip:
            guard starts([0x50, 0x4b, 0x03, 0x04]) || starts([0x50, 0x4b, 0x05, 0x06]) else { throw invalid(format) }
            let result = try await Shell.run("/usr/bin/unzip", ["-tqq", url.path], outputLimit: 64_000)
            guard result.succeeded, !result.outputTruncated else { throw invalid(format) }
        case .gz:
            guard starts([0x1f, 0x8b]) else { throw invalid(format) }
        case .tar:
            let result = try await Shell.run("/usr/bin/tar", ["-tf", url.path], outputLimit: 2_000_000)
            guard result.succeeded, !result.outputTruncated else { throw invalid(format) }
        case .txt, .md, .csv, .tsv, .srt, .vtt, .html:
            guard (try? TextFile.read(url)) != nil else { throw invalid(format) }
        default:
            guard (values.fileSize ?? 0) > 0 else { throw invalid(format) }
            let signatureMatches: Bool
            switch format {
            case .mp3: signatureMatches = starts(Array("ID3".utf8)) || (prefix.count >= 2 && prefix[0] == 0xff && prefix[1] & 0xe0 == 0xe0)
            case .wav: signatureMatches = starts(Array("RIFF".utf8)) && prefix.dropFirst(8).starts(with: Array("WAVE".utf8))
            case .aiff:
                signatureMatches =
                    starts(Array("FORM".utf8)) && (prefix.dropFirst(8).starts(with: Array("AIFF".utf8)) || prefix.dropFirst(8).starts(with: Array("AIFC".utf8)))
            case .flac: signatureMatches = starts(Array("fLaC".utf8))
            case .ogg, .opus: signatureMatches = starts(Array("OggS".utf8))
            case .mp4, .m4a, .mov:
                signatureMatches =
                    prefix.dropFirst(4).starts(with: Array("ftyp".utf8)) || (format == .mov && prefix.dropFirst(4).starts(with: Array("wide".utf8)))
            case .mkv, .webm: signatureMatches = starts([0x1a, 0x45, 0xdf, 0xa3])
            case .avi: signatureMatches = starts(Array("RIFF".utf8)) && prefix.dropFirst(8).starts(with: Array("AVI ".utf8))
            case .wmv, .wma: signatureMatches = starts([0x30, 0x26, 0xb2, 0x75, 0x8e, 0x66, 0xcf, 0x11])
            default: signatureMatches = false
            }
            guard signatureMatches else { throw invalid(format) }
        }
        try Task.checkCancellation()
    }

    private static func invalid(_ format: FileFormat) -> YuzuError {
        .invalidInput("The backend produced invalid \(format.displayName) data. No output was saved. Try a different format or check the backend in Settings.")
    }
}

/// Sibling staging and no-replace commit shared by conversion and tool operations.
enum OutputTransaction {
    static func stagingDirectory(for destination: URL) throws -> URL {
        let directory = destination.deletingLastPathComponent().appendingPathComponent(".yuzu-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return directory
    }

    static func preservePermissions(of source: URL, on output: URL) throws {
        let values = try output.resourceValues(forKeys: [.isDirectoryKey])
        let sourceMode = (try? FileManager.default.attributesOfItem(atPath: source.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0o600
        let mode = values.isDirectory == true ? 0o700 : (FileFormat.detect(output)?.category == .archive ? 0o600 : sourceMode & 0o666)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: output.path)
    }
    static func validateDestination(source: URL, destination: URL, format: FileFormat) throws {
        guard source.isFileURL, destination.isFileURL,
            source.resolvingSymlinksInPath().standardizedFileURL != destination.resolvingSymlinksInPath().standardizedFileURL,
            FileFormat.detect(destination) == format
        else { throw YuzuError.invalidInput("Choose a separate local destination with the \(format.fileExtension) extension.") }
        guard !FileManager.default.fileExists(atPath: destination.path),
            (try? destination.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true
        else { throw YuzuError.invalidInput("\(destination.lastPathComponent) already exists. Choose a different output name.") }
    }

    static func write(source: URL, destination: URL, format: FileFormat, work: (URL) async throws -> Void) async throws {
        try Task.checkCancellation()
        try validateDestination(source: source, destination: destination, format: format)
        let directory = try stagingDirectory(for: destination)
        let staging = directory.appendingPathComponent("output.\(format.fileExtension)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try await work(staging)
        try await OutputValidator.validate(staging, as: format)
        try Task.checkCancellation()
        try preservePermissions(of: source, on: staging)
        try FileManager.default.moveItem(at: staging, to: destination)
    }
}
