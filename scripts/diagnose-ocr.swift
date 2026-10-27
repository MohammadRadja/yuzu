import AppKit
import CoreImage
import CoreText
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

private struct DiagnosticError: Error { let message: String }

@main
@MainActor
struct OCRDiagnostics {
    static var selectedCase: String?

    static func fixture(width: Int = 1024, height: Int = 256) throws -> CGImage {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw DiagnosticError(message: "fixture context") }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(
                string: "Yuzu OCR 123",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 72), .foregroundColor: NSColor.black,
                ]))
        context.textPosition = CGPoint(x: 40, y: height / 3)
        CTLineDraw(line, context)
        guard let image = context.makeImage() else { throw DiagnosticError(message: "fixture image") }
        return image
    }

    static func gray(_ image: CGImage) throws -> CGImage {
        guard
            let context = CGContext(
                data: nil, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { throw DiagnosticError(message: "gray context") }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let result = context.makeImage() else { throw DiagnosticError(message: "gray image") }
        return result
    }

    static func data(_ image: CGImage, type: UTType) throws -> Data {
        let data = NSMutableData()
        guard let writer = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            throw DiagnosticError(message: "image writer")
        }
        CGImageDestinationAddImage(writer, image, nil)
        guard CGImageDestinationFinalize(writer) else { throw DiagnosticError(message: "image finalization") }
        return data as Data
    }

    static func grayBuffer(_ image: CGImage) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        guard
            CVPixelBufferCreate(
                kCFAllocatorDefault, image.width, image.height, kCVPixelFormatType_OneComponent8,
                nil, &buffer) == kCVReturnSuccess, let buffer,
            CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess
        else { throw DiagnosticError(message: "gray pixel buffer") }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard
            let context = CGContext(
                data: CVPixelBufferGetBaseAddress(buffer), width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { throw DiagnosticError(message: "gray buffer context") }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return buffer
    }

    static func probe(
        _ name: String, fast: Bool = false, cpu: Bool = false, explicitLanguage: Bool = false,
        revision: Int? = nil, deviceCPU: Bool = false, handler: () throws -> VNImageRequestHandler
    ) {
        guard selectedCase == nil || selectedCase == name else { return }
        print("OCR_BEGIN " + name)
        let started = Date()
        var result: [String: Any] = ["case": name]
        do {
            let request = VNRecognizeTextRequest()
            if let revision { request.revision = revision }
            request.recognitionLevel = fast ? .fast : .accurate
            request.usesLanguageCorrection = !explicitLanguage
            request.automaticallyDetectsLanguage = !explicitLanguage
            if explicitLanguage { request.recognitionLanguages = ["en-US"] }
            if cpu { request.usesCPUOnly = true }
            if deviceCPU {
                for (stage, devices) in try request.supportedComputeStageDevices {
                    guard
                        let selected = devices.first(where: {
                            if case .cpu = $0 { return true }; return false
                        })
                    else {
                        throw DiagnosticError(message: "No supported CPU device for \(stage)")
                    }
                    request.setComputeDevice(selected, for: stage)
                }
            }
            try handler().perform([request])
            let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
            result["text"] = text
            result["success"] = text.localizedCaseInsensitiveContains("Yuzu") && text.contains("123")
        } catch {
            let detail = error as NSError
            result["success"] = false
            result["error"] = String(reflecting: error)
            result["domain"] = detail.domain
            result["code"] = detail.code
            result["details"] = String(describing: detail.userInfo)
        }
        result["seconds"] = Date().timeIntervalSince(started)
        if let json = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) {
            print("OCR_PROBE " + String(decoding: json, as: UTF8.self))
        }
    }

    static func run() throws {
        let rgb = try fixture(), grayscale = try gray(rgb)
        let large = try fixture(width: 2000, height: 1000), largeGray = try gray(large)
        let png = try data(rgb, type: .png), grayPNG = try data(grayscale, type: .png), jpeg = try data(rgb, type: .jpeg)
        let buffer = try grayBuffer(rgb)
        let software = CIContext(options: [.useSoftwareRenderer: true, .cacheIntermediates: false])
        print("OCR_ENV " + ProcessInfo.processInfo.operatingSystemVersionString)
        print("OCR_REVISIONS \(VNRecognizeTextRequest.supportedRevisions)")
        if selectedCase == nil || selectedCase == "capabilities" {
            let languageRequest = VNRecognizeTextRequest()
            print("OCR_LANGUAGES \(String(describing: try? languageRequest.supportedRecognitionLanguages()))")
            print("OCR_COMPUTE \(String(describing: try? languageRequest.supportedComputeStageDevices))")
        }
        probe("rgba-device-cpu", deviceCPU: true) { VNImageRequestHandler(cgImage: rgb) }
        probe("rgba-cpu-only", cpu: true) { VNImageRequestHandler(cgImage: rgb) }
        probe("large-rgba-accurate-auto") { VNImageRequestHandler(cgImage: large) }
        probe("large-gray-accurate-auto") { VNImageRequestHandler(cgImage: largeGray) }
        probe("rgba-accurate-en", explicitLanguage: true) { VNImageRequestHandler(cgImage: rgb) }
        probe("gray-buffer-device-cpu", deviceCPU: true) { VNImageRequestHandler(cvPixelBuffer: buffer) }
        probe("rgba-accurate-auto") { VNImageRequestHandler(cgImage: rgb) }
        probe("gray-accurate-auto") { VNImageRequestHandler(cgImage: grayscale) }
        probe("gray-accurate-en", explicitLanguage: true) { VNImageRequestHandler(cgImage: grayscale) }
        probe("gray-fast-en", fast: true, explicitLanguage: true) { VNImageRequestHandler(cgImage: grayscale) }
        probe("gray-buffer-accurate-en", explicitLanguage: true) { VNImageRequestHandler(cvPixelBuffer: buffer) }
        probe("gray-buffer-cpu", cpu: true, explicitLanguage: true) { VNImageRequestHandler(cvPixelBuffer: buffer, options: [.ciContext: software]) }
        probe("gray-buffer-fast-cpu", fast: true, cpu: true, explicitLanguage: true) {
            VNImageRequestHandler(cvPixelBuffer: buffer, options: [.ciContext: software])
        }
        probe("png-data-auto") { VNImageRequestHandler(data: png) }
        probe("gray-png-data-auto") { VNImageRequestHandler(data: grayPNG) }
        probe("jpeg-data-en", explicitLanguage: true) { VNImageRequestHandler(data: jpeg) }
        probe("revision1-gray-fast", fast: true, cpu: true, explicitLanguage: true, revision: 1) { VNImageRequestHandler(cgImage: grayscale) }
        probe("revision2-gray-accurate", cpu: true, explicitLanguage: true, revision: 2) { VNImageRequestHandler(cgImage: grayscale) }
    }

    static func main() {
        selectedCase = CommandLine.arguments.dropFirst().first
        setbuf(stdout, nil)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "OCR diagnostics")
        Task { @MainActor in
            do { try run(); exit(0) } catch { print("OCR_DIAGNOSTIC_ERROR \(error)"); exit(1) }
        }
        withExtendedLifetime(activity) { app.run() }
    }
}
