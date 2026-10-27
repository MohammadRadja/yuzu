import Foundation

struct ConversionRequest {
    let source: URL
    let sourceFormat: FileFormat
    let target: FileFormat
    let destination: URL
    let progress: (Double) -> Void
}

protocol ConversionEngine {
    func supports(from: FileFormat, to: FileFormat) -> Bool
    func convert(_ request: ConversionRequest) async throws
}

enum Engines {
    static let all: [ConversionEngine] = [
        ExtraConversionEngine(),
        ImageEngine(),
        AudioEngine(),
        VideoEngine(),
        DocumentEngine(),
        OfficeEngine(),
        SpreadsheetEngine(),
        SubtitleEngine(),
        ArchiveEngine(),
    ]

    static func engine(from: FileFormat, to: FileFormat) -> ConversionEngine? {
        all.first { $0.supports(from: from, to: to) }
    }

    @discardableResult
    static func convert(_ request: ConversionRequest) async throws -> URL {
        try Task.checkCancellation()
        try OutputTransaction.validateDestination(source: request.source, destination: request.destination, format: request.target)
        guard FileManager.default.isReadableFile(atPath: request.source.path) else { throw YuzuError.unreadable(request.source) }
        guard ConversionMatrix.targets(for: request.sourceFormat).contains(request.target) else {
            throw YuzuError.unsupportedConversion(request.sourceFormat, request.target)
        }
        guard let engine = engine(from: request.sourceFormat, to: request.target) else {
            DiagnosticLog.log("no engine for \(request.sourceFormat.rawValue) -> \(request.target.rawValue)")
            throw YuzuError.unsupportedConversion(request.sourceFormat, request.target)
        }
        DiagnosticLog.log("engine \(type(of: engine)) \(request.sourceFormat.rawValue) -> \(request.target.rawValue) src=\(request.source.path)")
        let stagingDirectory = try OutputTransaction.stagingDirectory(for: request.destination)
        let temp = stagingDirectory.appendingPathComponent("output.\(request.target.fileExtension)")
        let staged = ConversionRequest(
            source: request.source,
            sourceFormat: request.sourceFormat,
            target: request.target,
            destination: temp,
            progress: request.progress
        )
        defer { try? FileManager.default.removeItem(at: stagingDirectory) }
        do {
            try await engine.convert(staged)
            try await OutputValidator.validate(temp, as: request.target)
            try Task.checkCancellation()
            try OutputTransaction.preservePermissions(of: request.source, on: temp)
            DiagnosticLog.log("engine finished, staged=\(temp.lastPathComponent)")
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: temp.path, isDirectory: &isDirectory) {
                if isDirectory.boolValue {
                    let folder = ConversionMatrix.uniqueDirectory(
                        directory: request.destination.deletingLastPathComponent(),
                        name: request.destination.deletingPathExtension().lastPathComponent
                    )
                    try FileManager.default.moveItem(at: temp, to: folder)
                    return folder
                } else {
                    try FileManager.default.moveItem(at: temp, to: request.destination)
                    return request.destination
                }
            }
            throw YuzuError.encodeFailed(request.destination.lastPathComponent)
        } catch {
            DiagnosticLog.log("engine threw: \(error)")
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }
}
