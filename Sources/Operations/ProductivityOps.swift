import AppKit
import CoreText
import Foundation
import PDFKit
import Vision

enum PDFDrawing {
    static func size(of page: CGPDFPage) -> CGSize {
        let box = page.getBoxRect(.mediaBox)
        return abs(page.rotationAngle) % 180 == 90 ? CGSize(width: box.height, height: box.width) : box.size
    }

    static func raster(_ page: CGPDFPage, longEdge: Int = 2000) throws -> CGImage {
        let size = size(of: page)
        guard size.width > 0, size.height > 0, size.width.isFinite, size.height.isFinite else { throw YuzuError.invalidInput("Invalid PDF page dimensions.") }
        let scale = min(Double(longEdge) / max(size.width, size.height), 4)
        let width = max(1, Int(size.width * scale)), height = max(1, Int(size.height * scale))
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw YuzuError.encodeFailed("PDF page preview") }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(NSColor.white.cgColor)
        context.fill(rect)
        context.concatenate(page.getDrawingTransform(.mediaBox, rect: rect, rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(page)
        guard let result = context.makeImage() else { throw YuzuError.encodeFailed("PDF page preview") }
        return result
    }

    static func rewrite(
        _ source: URL, to destination: URL, overlay: (CGContext, CGSize, Int) throws -> Void,
        progress: (Double) -> Void
    ) throws {
        guard let document = CGPDFDocument(source as CFURL), !document.isEncrypted, (1...1000).contains(document.numberOfPages),
            let context = CGContext(destination as CFURL, mediaBox: nil, nil)
        else { throw YuzuError.invalidInput("Choose an unlocked PDF with 1–1000 pages.") }
        defer { context.closePDF() }
        for index in 1...document.numberOfPages {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else { throw YuzuError.unreadable(source) }
            let size = size(of: page)
            var box = CGRect(origin: .zero, size: size)
            let info = [kCGPDFContextMediaBox as String: Data(bytes: &box, count: MemoryLayout<CGRect>.size)] as CFDictionary
            context.beginPDFPage(info)
            context.saveGState()
            context.concatenate(page.getDrawingTransform(.mediaBox, rect: box, rotate: 0, preserveAspectRatio: true))
            context.drawPDFPage(page)
            context.restoreGState()
            try overlay(context, size, index - 1)
            context.endPDFPage()
            progress(Double(index) / Double(document.numberOfPages))
        }
    }
}

struct WatermarkOptions: Equatable {
    enum Position: String, CaseIterable, Identifiable {
        case center = "Center", topLeft = "Top Left", topRight = "Top Right", bottomLeft = "Bottom Left", bottomRight = "Bottom Right"
        var id: String { rawValue }
        var anchor: CGPoint {
            switch self {
            case .center: return CGPoint(x: 0.5, y: 0.5)
            case .topLeft: return CGPoint(x: 0.25, y: 0.8)
            case .topRight: return CGPoint(x: 0.75, y: 0.8)
            case .bottomLeft: return CGPoint(x: 0.25, y: 0.2)
            case .bottomRight: return CGPoint(x: 0.75, y: 0.2)
            }
        }
    }
    var text = "Yuzu"
    var image: URL?
    var position = Position.center
    var width = 0.3
    var opacity = 0.5
    var rotation = 0.0
}

enum WatermarkOps {
    static func draw(_ context: CGContext, size: CGSize, options: WatermarkOptions) throws {
        guard (0.05...0.9).contains(options.width), (0...1).contains(options.opacity), options.rotation.isFinite,
            options.image != nil || !options.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw YuzuError.invalidInput("Choose watermark content, width, and opacity.") }
        let targetWidth = size.width * options.width
        context.saveGState()
        defer { context.restoreGState() }
        context.translateBy(x: size.width * options.position.anchor.x, y: size.height * options.position.anchor.y)
        context.rotate(by: options.rotation * .pi / 180)
        context.setAlpha(options.opacity)
        if let url = options.image {
            let image = try ImageIOBridge.load(url, maxPixelSize: 4096)
            let height = targetWidth * CGFloat(image.height) / CGFloat(image.width)
            context.draw(image, in: CGRect(x: -targetWidth / 2, y: -height / 2, width: targetWidth, height: height))
        } else {
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 100, weight: .semibold), .foregroundColor: NSColor.black]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: options.text, attributes: attributes))
            let bounds = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
            guard bounds.width > 0 else { throw YuzuError.invalidInput("Enter visible watermark text.") }
            let scale = targetWidth / bounds.width
            context.scaleBy(x: scale, y: scale)
            context.textMatrix = .identity
            context.textPosition = CGPoint(x: -bounds.midX, y: -bounds.midY)
            CTLineDraw(line, context)
        }
    }

    static func render(_ image: CGImage, options: WatermarkOptions) throws -> CGImage {
        guard image.width * image.height <= 100_000_000,
            let context = CGContext(
                data: nil, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw YuzuError.encodeFailed("watermark preview") }
        let size = CGSize(width: image.width, height: image.height)
        context.draw(image, in: CGRect(origin: .zero, size: size))
        try draw(context, size: size, options: options)
        guard let output = context.makeImage() else { throw YuzuError.encodeFailed("watermark") }
        return output
    }

    static func export(_ source: URL, to destination: URL, options: WatermarkOptions, progress: @escaping (Double) -> Void) async throws {
        let format: FileFormat = FileFormat.detect(source) == .pdf ? .pdf : .png
        try await OutputTransaction.write(source: source, destination: destination, format: format) { staged in
            if format == .pdf {
                try PDFDrawing.rewrite(source, to: staged, overlay: { context, size, _ in try draw(context, size: size, options: options) }, progress: progress)
            } else {
                let image = try render(ImageIOBridge.load(source), options: options)
                try ImageIOBridge.write(image, to: staged, format: .png)
                progress(1)
            }
        }
    }

    static func preview(_ source: URL, options: WatermarkOptions) async throws -> CGImage {
        let image: CGImage
        if FileFormat.detect(source) == .pdf {
            guard let document = CGPDFDocument(source as CFURL), let page = document.page(at: 1) else { throw YuzuError.unreadable(source) }
            image = try PDFDrawing.raster(page, longEdge: 1000)
        } else {
            image = try ImageIOBridge.load(source, maxPixelSize: 1000)
        }
        return try render(image, options: options)
    }
}

enum PDFPasswordOps {
    static func export(_ source: URL, to destination: URL, currentPassword: String, newPassword: String?, authorized: Bool) async throws {
        guard authorized else { throw YuzuError.invalidInput("Confirm that you are authorized to change this PDF's protection.") }
        guard let document = PDFDocument(url: source) else { throw YuzuError.unreadable(source) }
        if document.isEncrypted {
            guard !currentPassword.isEmpty, document.unlock(withPassword: currentPassword) else {
                throw YuzuError.invalidInput("The current PDF password is incorrect.")
            }
        }
        let count = document.pageCount
        guard count > 0 else { throw YuzuError.invalidInput("The PDF has no readable pages.") }
        let output = PDFDocument()
        output.documentAttributes = document.documentAttributes
        for index in 0..<count {
            try Task.checkCancellation()
            guard let copy = document.page(at: index)?.copy() as? PDFPage else { throw YuzuError.unreadable(source) }
            output.insert(copy, at: index)
        }
        var options: [PDFDocumentWriteOption: Any] = [:]
        if let newPassword {
            guard !newPassword.isEmpty else { throw YuzuError.invalidInput("Enter a new PDF password.") }
            options = [.userPasswordOption: newPassword, .ownerPasswordOption: newPassword]
        }
        try await OutputTransaction.write(source: source, destination: destination, format: .pdf) { staged in
            guard output.write(to: staged, withOptions: options), let check = PDFDocument(url: staged) else { throw YuzuError.encodeFailed("PDF protection") }
            if let newPassword {
                guard check.isEncrypted, check.unlock(withPassword: newPassword), check.pageCount == count else {
                    throw YuzuError.encodeFailed("PDF encryption")
                }
            } else {
                guard !check.isEncrypted, check.pageCount == count else { throw YuzuError.encodeFailed("unlocked PDF") }
            }
        }
    }
}

enum OCROps {
    static func recognize(
        _ image: CGImage,
        perform: ((VNImageRequestHandler, VNRecognizeTextRequest) throws -> Void)? = nil
    ) throws -> String {
        try Task.checkCancellation()
        func makeRequest() -> VNRecognizeTextRequest {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            return request
        }
        let execute = perform ?? { try $0.perform([$1]) }
        var request = makeRequest()
        do {
            try execute(VNImageRequestHandler(cgImage: image), request)
        } catch {
            try Task.checkCancellation()
            // Some virtualized Macs cannot execute Vision's accelerated path.
            // Retry once with a fresh request and only supported CPU devices.
            let fallback = makeRequest()
            let stages = try fallback.supportedComputeStageDevices
            guard !stages.isEmpty else { throw error }
            for (stage, devices) in stages {
                guard
                    let cpu = devices.first(where: {
                        if case .cpu = $0 { return true }; return false
                    })
                else { throw error }
                fallback.setComputeDevice(cpu, for: stage)
            }
            try execute(VNImageRequestHandler(cgImage: image), fallback)
            request = fallback
        }
        try Task.checkCancellation()
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    static func text(_ source: URL, progress: @escaping (Double) -> Void) async throws -> String {
        if FileFormat.detect(source) != .pdf {
            let result = try recognize(ImageIOBridge.load(source, maxPixelSize: 4000))
            progress(1)
            return result
        }
        guard let document = CGPDFDocument(source as CFURL), !document.isEncrypted, (1...500).contains(document.numberOfPages) else {
            throw YuzuError.invalidInput("Choose an unlocked PDF with 1–500 pages for OCR.")
        }
        var pages: [String] = []
        for index in 1...document.numberOfPages {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else { throw YuzuError.unreadable(source) }
            pages.append(try autoreleasepool { try recognize(PDFDrawing.raster(page)) })
            progress(Double(index) / Double(document.numberOfPages))
        }
        return pages.joined(separator: "\n\u{c}\n")
    }

    static func export(_ source: URL, to destination: URL, progress: @escaping (Double) -> Void) async throws {
        try await OutputTransaction.write(source: source, destination: destination, format: .txt) { staged in
            let result = try await text(source, progress: progress)
            guard !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw YuzuError.invalidInput("No text was recognized. Try a clearer or higher-resolution scan.")
            }
            try result.write(to: staged, atomically: false, encoding: .utf8)
        }
    }
}
