import Foundation

struct WorkflowStep: Identifiable, Equatable, Codable {
    enum Kind: String, CaseIterable, Codable {
        case convert = "Convert", optimize = "Optimize", resize = "Resize Image", ocr = "OCR to TXT"
    }
    var id = UUID()
    var kind = Kind.convert
    var target = "png"
    var longEdge = 1920
    var preset = "balanced"
}

enum WorkflowEngine {
    static func validate(_ steps: [WorkflowStep], source: FileFormat, capabilities: BackendCapabilities = RuntimeCapabilities.snapshot) throws -> FileFormat {
        guard (1...16).contains(steps.count), source.category != .archive else {
            throw YuzuError.invalidInput("Use 1–16 steps and a supported non-archive input.")
        }
        var current = source
        for (index, step) in steps.enumerated() {
            switch step.kind {
            case .convert:
                guard let target = FileFormat(rawValue: step.target), target.category != .archive,
                    ConversionMatrix.targets(for: current).contains(target), capabilities.supports(from: current, to: target),
                    !([FileFormat.pdf, .ppt, .pptx].contains(current) && (target.category == .image))
                else {
                    throw YuzuError.invalidInput("Step \(index + 1) cannot convert \(current.displayName) to \(step.target.uppercased()) as a single file.")
                }
                current = target
            case .optimize:
                guard capabilities.supports(tool: .compress, formats: [current]), CompressionPreset(rawValue: step.preset) != nil else {
                    throw YuzuError.invalidInput("Step \(index + 1) cannot optimize \(current.displayName).")
                }
                current = Compressor.outputFormat(for: URL(fileURLWithPath: "/workflow/input.\(current.fileExtension)"))
            case .resize:
                guard current.category == .image, (1...16384).contains(step.longEdge) else {
                    throw YuzuError.invalidInput("Resize needs an image and a longest edge between 1 and 16384 pixels.")
                }
                current = .png
            case .ocr:
                guard current.category == .image || current == .pdf else { throw YuzuError.invalidInput("OCR needs an image or PDF.") }
                current = .txt
            }
        }
        return current
    }

    static func run(_ source: URL, steps: [WorkflowStep], to destination: URL, progress: @escaping (Double) -> Void) async throws {
        guard let sourceFormat = FileFormat.detect(source) else { throw YuzuError.unreadable(source) }
        let capabilities = await RuntimeCapabilities.refresh()
        let target = try validate(steps, source: sourceFormat, capabilities: capabilities)
        try await OutputTransaction.write(source: source, destination: destination, format: target) { staged in
            let workspace = staged.deletingLastPathComponent().appendingPathComponent(".yuzu-workflow-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: workspace) }
            var input = source
            var format = sourceFormat
            for (index, step) in steps.enumerated() {
                try Task.checkCancellation()
                let outputFormat = try validate([step], source: format, capabilities: capabilities)
                let output = workspace.appendingPathComponent("step-\(index + 1).\(outputFormat.fileExtension)")
                let report: (Double) -> Void = { progress((Double(index) + $0) / Double(steps.count)) }
                switch step.kind {
                case .convert:
                    input = try await Engines.convert(
                        ConversionRequest(source: input, sourceFormat: format, target: outputFormat, destination: output, progress: report))
                case .optimize:
                    try await Compressor.compress(
                        input, preset: CompressionPreset(rawValue: step.preset) ?? .balanced, resizeLongEdge: 0, targetBytes: nil, to: output, progress: report)
                    input = output
                case .resize:
                    let image = try ImageIOBridge.load(input)
                    try ImageIOBridge.write(ImageIOBridge.resized(image, longEdge: step.longEdge), to: output, format: .png)
                    input = output
                case .ocr:
                    try await OCROps.export(input, to: output, progress: report)
                    input = output
                }
                try await OutputValidator.validate(input, as: outputFormat)
                format = outputFormat
                progress(Double(index + 1) / Double(steps.count))
            }
            try FileManager.default.copyItem(at: input, to: staged)
        }
    }
}
