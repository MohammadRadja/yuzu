import CoreImage
import Foundation
import Vision

enum AdvancedImageOps {
    static func removeBackground(_ source: URL, to destination: URL) async throws {
        try await OutputTransaction.write(source: source, destination: destination, format: .png) { staged in
            let image = try ImageIOBridge.load(source, maxPixelSize: 8192)
            let handler = VNImageRequestHandler(cgImage: image)
            let request = VNGenerateForegroundInstanceMaskRequest()
            try handler.perform([request])
            try Task.checkCancellation()
            guard let observation = request.results?.first, !observation.allInstances.isEmpty else {
                throw YuzuError.invalidInput("Vision could not identify a foreground subject in this image.")
            }
            let mask = try observation.generateScaledMaskForImage(forInstances: observation.allInstances, from: handler)
            let input = CIImage(cgImage: image)
            let result = input.applyingFilter(
                "CIBlendWithMask",
                parameters: [kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: input.extent), kCIInputMaskImageKey: CIImage(cvPixelBuffer: mask)])
            guard let output = ImageOps.render(result, extent: input.extent) else { throw YuzuError.encodeFailed("foreground mask") }
            try ImageIOBridge.write(output, to: staged, format: .png)
        }
    }

    static func upscale(_ source: URL, factor: Double, to destination: URL) async throws {
        guard [2.0, 4.0].contains(factor) else { throw YuzuError.invalidInput("Choose a 2× or 4× upscale.") }
        try await OutputTransaction.write(source: source, destination: destination, format: .png) { staged in
            let image = try ImageIOBridge.load(source)
            guard Double(image.width) * Double(image.height) * factor * factor <= 100_000_000 else {
                throw YuzuError.invalidInput("The upscaled image would exceed 100 megapixels. Use a smaller source or scale.")
            }
            let input = CIImage(cgImage: image)
            let result = input.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: factor, kCIInputAspectRatioKey: 1])
            guard let output = ImageOps.render(result) else { throw YuzuError.encodeFailed("Lanczos upscale") }
            try Task.checkCancellation()
            try ImageIOBridge.write(output, to: staged, format: .png)
        }
    }
}

enum VisualPDFSignature {
    static func preview(_ source: URL, page: Int, options: WatermarkOptions) async throws -> CGImage {
        guard let document = CGPDFDocument(source as CFURL), let selected = document.page(at: page) else {
            throw YuzuError.invalidInput("Choose an existing PDF page.")
        }
        return try WatermarkOps.render(PDFDrawing.raster(selected, longEdge: 1000), options: options)
    }
    static func export(_ source: URL, to destination: URL, page: Int, options: WatermarkOptions) async throws {
        guard options.image != nil, let document = CGPDFDocument(source as CFURL), (1...document.numberOfPages).contains(page) else {
            throw YuzuError.invalidInput("Choose a signature image and an existing PDF page.")
        }
        try await OutputTransaction.write(source: source, destination: destination, format: .pdf) { staged in
            try PDFDrawing.rewrite(
                source, to: staged,
                overlay: { context, size, index in
                    if index == page - 1 { try WatermarkOps.draw(context, size: size, options: options) }
                }, progress: { _ in })
        }
    }
}

struct FileComparisonResult {
    let identical: Bool
    let firstText: String?
    let secondText: String?
    let insertions: Int?
    let removals: Int?
}

enum FileComparison {
    static func compare(_ first: URL, _ second: URL) async throws -> FileComparisonResult {
        let equal = try FileHash.sha256(first) == FileHash.sha256(second)
        var a: String?, b: String?, insertions: Int?, removals: Int?
        if FileSizeFormatter.size(of: first) <= 1_048_576, FileSizeFormatter.size(of: second) <= 1_048_576 {
            a = try? String(contentsOf: first, encoding: .utf8)
            b = try? String(contentsOf: second, encoding: .utf8)
            if let a, let b {
                let linesA = a.components(separatedBy: .newlines), linesB = b.components(separatedBy: .newlines)
                if linesA.count + linesB.count <= 10_000 {
                    try Task.checkCancellation()
                    let changes = linesB.difference(from: linesA)
                    insertions = changes.insertions.count
                    removals = changes.removals.count
                }
            }
        }
        return FileComparisonResult(identical: equal, firstText: a, secondText: b, insertions: insertions, removals: removals)
    }
}
