import AppKit
import Foundation
import ImageIO

enum IconWriter {
    private static func png(_ image: CGImage, size: Int) throws -> Data {
        guard
            let context = CGContext(
                data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw YuzuError.encodeFailed("icon canvas") }
        let scale = min(CGFloat(size) / CGFloat(image.width), CGFloat(size) / CGFloat(image.height))
        let rect = CGRect(
            x: (CGFloat(size) - CGFloat(image.width) * scale) / 2, y: (CGFloat(size) - CGFloat(image.height) * scale) / 2,
            width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        context.interpolationQuality = .high
        context.draw(image, in: rect)
        guard let output = context.makeImage() else { throw YuzuError.encodeFailed("icon") }
        let bytes = NSMutableData()
        guard let encoder = CGImageDestinationCreateWithData(bytes, "public.png" as CFString, 1, nil) else { throw YuzuError.encodeFailed("icon PNG") }
        CGImageDestinationAddImage(encoder, output, nil)
        guard CGImageDestinationFinalize(encoder) else { throw YuzuError.encodeFailed("icon PNG") }
        return bytes as Data
    }
    static func write(_ image: CGImage, to url: URL, icns: Bool) throws {
        func number<T: FixedWidthInteger>(_ value: T, bigEndian: Bool = false) -> Data {
            var encoded = bigEndian ? value.bigEndian : value.littleEndian
            return Data(bytes: &encoded, count: MemoryLayout<T>.size)
        }
        if icns {
            let chunks = [(16, "icp4"), (32, "icp5"), (64, "icp6"), (128, "ic07"), (256, "ic08"), (512, "ic09"), (1024, "ic10")]
            var body = Data()
            for (size, type) in chunks {
                try Task.checkCancellation()
                let imageData = try png(image, size: size)
                body.append(Data(type.utf8)); body.append(number(UInt32(imageData.count + 8), bigEndian: true)); body.append(imageData)
            }
            var output = Data("icns".utf8)
            output.append(number(UInt32(body.count + 8), bigEndian: true)); output.append(body)
            try output.write(to: url)
        } else {
            let sizes = [32, 64, 128, 256]
            let images = try sizes.map { try png(image, size: $0) }
            var output = number(UInt16(0)) + number(UInt16(1)) + number(UInt16(sizes.count))
            var offset = UInt32(6 + 16 * sizes.count)
            for (size, data) in zip(sizes, images) {
                output.append(contentsOf: [size == 256 ? 0 : UInt8(size), size == 256 ? 0 : UInt8(size), 0, 0])
                output.append(number(UInt16(1))); output.append(number(UInt16(32)))
                output.append(number(UInt32(data.count))); output.append(number(offset)); offset += UInt32(data.count)
            }
            for image in images { output.append(image) }
            try output.write(to: url)
        }
    }
}

enum AnimatedGIFWriter {
    static func write(_ urls: [URL], to destination: URL, delay: Double = 0.2, progress: @escaping (Double) -> Void) async throws {
        guard (2...500).contains(urls.count), (0.02...10).contains(delay), let first = urls.first else {
            throw YuzuError.invalidInput("Choose 2–500 images and a valid frame delay.")
        }
        try await OutputTransaction.write(source: first, destination: destination, format: .gif) { staged in
            guard let encoder = CGImageDestinationCreateWithURL(staged as CFURL, "com.compuserve.gif" as CFString, urls.count, nil) else {
                throw YuzuError.encodeFailed("animated GIF")
            }
            CGImageDestinationSetProperties(encoder, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
            let canvas = ImageIOBridge.pixelSize(first)
            guard canvas.width > 0, canvas.height > 0 else { throw YuzuError.unreadable(first) }
            let factor = min(1, 1024 / max(canvas.width, canvas.height))
            let size = CGSize(width: max(1, Int(canvas.width * factor)), height: max(1, Int(canvas.height * factor)))
            for (index, url) in urls.enumerated() {
                try Task.checkCancellation()
                let image = try ImageIOBridge.load(url, maxPixelSize: 1024)
                guard
                    let context = CGContext(
                        data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                else { throw YuzuError.encodeFailed("GIF frame") }
                let scale = min(size.width / CGFloat(image.width), size.height / CGFloat(image.height))
                context.draw(
                    image,
                    in: CGRect(
                        x: (size.width - CGFloat(image.width) * scale) / 2, y: (size.height - CGFloat(image.height) * scale) / 2,
                        width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale))
                guard let frame = context.makeImage() else { throw YuzuError.encodeFailed("GIF frame") }
                CGImageDestinationAddImage(
                    encoder, frame,
                    [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay, kCGImagePropertyGIFUnclampedDelayTime: delay]] as CFDictionary)
                progress(Double(index + 1) / Double(urls.count + 1))
            }
            guard CGImageDestinationFinalize(encoder) else { throw YuzuError.encodeFailed("animated GIF") }
            guard let check = CGImageSourceCreateWithURL(staged as CFURL, nil), CGImageSourceGetCount(check) == urls.count else {
                throw YuzuError.encodeFailed("GIF frame validation")
            }
        }
        progress(1)
    }
}

enum LocalHTMLText {
    static func read(_ source: URL) throws -> String {
        let text = try TextFile.read(source)
        guard text.utf8.count <= 8_388_608, !text.uppercased().contains("<!ENTITY") else {
            throw YuzuError.invalidInput("HTML exceeds the size limit or declares external entities.")
        }
        let document = try XMLDocument(xmlString: text, options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever])
        func extract(_ node: XMLNode, depth: Int = 0) throws -> String {
            guard depth < 128 else { throw YuzuError.invalidInput("HTML nesting limit exceeded.") }
            if ["head", "script", "style", "iframe", "object", "noscript"].contains(node.name?.lowercased() ?? "") { return "" }
            if node.kind == .text { return node.stringValue ?? "" }
            let content = try (node.children ?? []).map { try extract($0, depth: depth + 1) }.joined()
            return content + (["p", "div", "br", "li", "tr", "h1", "h2", "h3", "section"].contains(node.name?.lowercased() ?? "") ? "\n" : "")
        }
        return try extract(document).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum TextClippingReader {
    static func read(_ source: URL) throws -> String {
        let values = try source.resourceValues(forKeys: [.fileSizeKey])
        guard (values.fileSize ?? 0) <= 8_388_608,
            let object = try PropertyListSerialization.propertyList(from: Data(contentsOf: source), format: nil) as? [String: Any],
            let data = object["UTI-Data"] as? [String: Any]
        else { throw YuzuError.invalidInput("This clipping has no supported property-list text. Recreate legacy resource-fork clippings in Finder first.") }
        for (key, encoding) in [
            ("public.utf8-plain-text", String.Encoding.utf8), ("public.utf16-plain-text", .utf16), ("com.apple.traditional-mac-plain-text", .macOSRoman),
        ] {
            if let text = data[key] as? String { return text }
            if let bytes = data[key] as? Data, let text = String(data: bytes, encoding: encoding) { return text }
        }
        throw YuzuError.invalidInput("The clipping contains no supported plain-text representation.")
    }
}

struct ExtraConversionEngine: ConversionEngine {
    func supports(from: FileFormat, to: FileFormat) -> Bool {
        [.html, .textClipping, .json, .yaml, .xml].contains(from) && ConversionMatrix.targets(for: from).contains(to) || from == .pdf && to == .svg
    }
    func convert(_ request: ConversionRequest) async throws {
        if request.sourceFormat == .pdf {
            guard let document = CGPDFDocument(request.source as CFURL), !document.isEncrypted, (1...500).contains(document.numberOfPages) else {
                throw YuzuError.unreadable(request.source)
            }
            if document.numberOfPages > 1 { try FileManager.default.createDirectory(at: request.destination, withIntermediateDirectories: false) }
            for index in 1...document.numberOfPages {
                try Task.checkCancellation()
                guard let page = document.page(at: index) else { throw YuzuError.unreadable(request.source) }
                let image = try PDFDrawing.raster(page)
                let temp = FileManager.default.temporaryDirectory.appendingPathComponent("yuzu-svg-\(UUID().uuidString).png")
                defer { try? FileManager.default.removeItem(at: temp) }
                try ImageIOBridge.write(image, to: temp, format: .png)
                let base64 = try Data(contentsOf: temp).base64EncodedString()
                let svg =
                    "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(image.width)\" height=\"\(image.height)\" viewBox=\"0 0 \(image.width) \(image.height)\"><image width=\"100%\" height=\"100%\" href=\"data:image/png;base64,\(base64)\"/></svg>"
                let output = document.numberOfPages == 1 ? request.destination : request.destination.appendingPathComponent("page-\(index).svg")
                try svg.write(to: output, atomically: false, encoding: .utf8)
                request.progress(Double(index) / Double(document.numberOfPages))
            }
        } else if [.json, .yaml, .xml].contains(request.sourceFormat) {
            let text = try TextFile.read(request.source)
            guard text.utf8.count <= 8_388_608 else { throw YuzuError.invalidInput("Structured input exceeds 8 MiB.") }
            let value: Any
            switch request.sourceFormat {
            case .json: value = try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
            case .yaml: value = try YAMLDocument.read(text)
            default: value = try XMLJSON.read(text)
            }
            let output: String
            switch request.target {
            case .json:
                output = String(
                    decoding: try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]), as: UTF8.self)
            case .yaml: output = try YAMLDocument.write(value) + "\n"
            case .xml: output = try XMLJSON.write(value)
            default: throw YuzuError.unsupportedConversion(request.sourceFormat, request.target)
            }
            try output.write(to: request.destination, atomically: false, encoding: .utf8)
        } else {
            let text = request.sourceFormat == .html ? try LocalHTMLText.read(request.source) : try TextClippingReader.read(request.source)
            switch request.target {
            case .pdf: try TextRenderer.writePDF(text, to: request.destination)
            case .docx: try await DocxWriter.write(paragraphs: text.components(separatedBy: .newlines), images: [], to: request.destination)
            case .txt, .md: try DocumentText.write(text, as: request.target, to: request.destination)
            default: throw YuzuError.unsupportedConversion(request.sourceFormat, request.target)
            }
        }
        request.progress(1)
    }
}
