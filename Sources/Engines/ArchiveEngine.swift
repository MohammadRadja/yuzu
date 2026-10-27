import Foundation

struct ArchiveEngine: ConversionEngine {
    func supports(from: FileFormat, to: FileFormat) -> Bool {
        from.category == .archive && to.category == .archive && to != .rar
    }

    func convert(_ request: ConversionRequest) async throws {
        if request.target == .rar {
            throw YuzuError.invalidInput("RAR archives can be read but macOS has no free RAR encoder. Choose ZIP, TAR, or GZIP instead.")
        }
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("yuzu-archive-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        let contents = staging.appendingPathComponent("contents")
        try await extract(request.source, format: request.sourceFormat, into: contents)
        request.progress(0.5)
        try await pack(contents, as: request.target, to: request.destination)
        request.progress(1)
    }

    func extract(_ archive: URL, format: FileFormat, into directory: URL) async throws {
        try await FileOperations.extract(archive, to: directory, progress: { _ in })
    }

    func pack(_ directory: URL, as format: FileFormat, to destination: URL) async throws {
        switch format {
        case .zip:
            try await ZipTool.zip(directory: directory, to: destination)
        case .tar:
            let result = try await Shell.run("/usr/bin/tar", ["-cf", destination.path, "-C", directory.path, "."])
            guard result.succeeded else { throw YuzuError.toolFailed("tar", result.stderr) }
        case .gz:
            let result = try await Shell.run("/usr/bin/tar", ["-czf", destination.path, "-C", directory.path, "."])
            guard result.succeeded else { throw YuzuError.toolFailed("tar", result.stderr) }
        default:
            throw YuzuError.unsupportedConversion(.zip, format)
        }
    }
}
