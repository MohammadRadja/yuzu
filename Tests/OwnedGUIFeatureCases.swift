import AppKit
import Foundation
import ImageIO
import PDFKit
import SwiftUI

@MainActor
extension OwnedGUIValidation {
    final class PickerKeepers {
        static let shared = PickerKeepers()
        var controllers: [RadialController] = []
    }

    static func cleanupFeatures() {
        for controller in PickerKeepers.shared.controllers { controller.hide() }
        PickerKeepers.shared.controllers.removeAll()
        cleanup()
    }

    static func clickContaining(_ query: String, in window: NSWindow) async throws {
        func button() -> Element? { window.contentView.flatMap { elements($0).first { $0.role == "AXButton" && $0.text.contains(query) } } }
        try await wait("button containing " + query) { button() != nil }
        guard let item = button() else { throw TestFailure(description: "button missing") }
        try item.press()
        try await Task.sleep(nanoseconds: 80_000_000)
    }

    static func choose(_ action: RadialAction, files: [URL], mode: RadialMode = .conversion) async throws {
        let controller = RadialController()
        PickerKeepers.shared.controllers.append(controller)
        controller.presentPicker(for: files, mode: mode)
        guard let panel = NSApp.windows.compactMap({ $0 as? RadialPanel }).first(where: \.isVisible) else {
            throw TestFailure(description: "Radial not presented")
        }
        func contains(_ item: RadialItem) -> Bool {
            if item.action == action { return true }
            if case .more(let nested) = item.action { return nested.contains(where: contains) }
            return false
        }
        guard let item = panel.radialView.items.first(where: contains) else { throw TestFailure(description: "Requested action is not available") }
        try await click("radial.item." + item.label, in: panel)
        if case .more(let nested) = item.action {
            try await wait("More panel") { FeatureWindows.shared.openWindows.contains { $0.isVisible && $0.title == "More" } }
            guard let more = FeatureWindows.shared.openWindows.first(where: { $0.isVisible && $0.title == "More" }),
                let target = nested.first(where: { $0.action == action })
            else { throw TestFailure(description: "More action missing") }
            try await click("radial.more." + target.label, in: more)
        }
    }

    static func setSelected(_ element: Element) throws {
        var object: NSObject? = element.object
        for _ in 0..<12 {
            guard let node = object else { break }
            let selector = NSSelectorFromString("setAccessibilitySelected:")
            if node.responds(to: selector) {
                typealias SetSelected = @convention(c) (AnyObject, Selector, Bool) -> Void
                unsafeBitCast(node.method(for: selector), to: SetSelected.self)(node, selector, true)
                return
            }
            object = Element(node).value("accessibilityParent") as? NSObject
        }
        throw TestFailure(description: "Selectable row unavailable: \(element.text)")
    }

    static func jobFailures() async throws -> [Job] {
        try await wait("job submission") { !JobRunner.shared.jobs.isEmpty }
        let jobs = JobRunner.shared.jobs
        try await wait("terminal jobs", timeout: 40) { jobs.allSatisfy { $0.status.isFinished } }
        return jobs
    }

    static func registerFeatures(_ runner: TestRunner) async {
        await runner.testAsync("GUI Make a Copy duplicates a file and folder and preserves an existing copy") {
            try await withDocumentFixture { directory in
                defer { cleanupFeatures() }
                let file = directory.appendingPathComponent("original.txt"), existing = directory.appendingPathComponent("original copy.txt")
                try Data("original content".utf8).write(to: file)
                try Data("existing content".utf8).write(to: existing)
                try await choose(.file(.duplicate), files: [file], mode: .actions)
                let outputs = try await finishJobs()
                guard let copied = outputs.first else { throw TestFailure(description: "copy output missing") }
                try expect(copied != existing, "unique name")
                try expectEqual(try TextFile.read(copied), "original content")
                try expectEqual(try TextFile.read(existing), "existing content")
                cleanupFeatures()
                let folder = directory.appendingPathComponent("folder")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
                try Data("nested".utf8).write(to: folder.appendingPathComponent("file.txt"))
                try await choose(.file(.duplicate), files: [folder], mode: .actions)
                let folders = try await finishJobs()
                guard let copy = folders.first else { throw TestFailure(description: "folder copy missing") }
                try expectEqual(try TextFile.read(copy.appendingPathComponent("file.txt")), "nested")
            }
        }

        await runner.testAsync("GUI Extract uses an entered password and keeps panel open after wrong password") {
            try await withDocumentFixture { directory in
                defer { cleanupFeatures() }
                let file = directory.appendingPathComponent("secret.txt"), zip = directory.appendingPathComponent("protected.zip")
                try Data("archive fixture".utf8).write(to: file)
                try await EncryptedZIP.create([file], to: zip, password: "fixture-password", progress: { _ in })
                let window = FeatureWindows.shared.show("QA Extract") { ArchiveActionView(files: [zip], creating: false, showAdvanced: true) }
                try await edit("archive.password", "wrong", in: window)
                try await click("Extract all", in: window)
                let failed = try await jobFailures()
                try expect(
                    failed.contains {
                        if case .failed = $0.status { return true }; return false
                    }, "wrong password refused")
                try expect(window.isVisible, "failed submission stays available")
                JobRunner.shared.dismissAll()
                try await edit("archive.password", "fixture-password", in: window)
                try await click("Extract all", in: window)
                let outputs = try await finishJobs()
                guard let folder = outputs.first else { throw TestFailure(description: "extraction missing") }
                try expectEqual(try TextFile.read(folder.appendingPathComponent("secret.txt")), "archive fixture")
                try await wait("extract closes after success") { !window.isVisible }
            }
        }

        await runner.testAsync("GUI Batch Rename edits preview confirms names and detects conflicts before moving") {
            try await withDocumentFixture { directory in
                defer { cleanupFeatures() }
                let files = ["one.txt", "two.txt"].map { directory.appendingPathComponent($0) }
                for (index, file) in files.enumerated() { try Data("file \(index)".utf8).write(to: file) }
                let window = FeatureWindows.shared.show("QA Rename") { TaskPanel(task: .batchRename, files: files) }
                try await edit("rename.pattern", "same", in: window)
                try await wait("conflict disables apply") { window.contentView.flatMap { elements($0).first { $0.id == "task.apply" } }?.enabled == false }
                try await edit("rename.pattern", "{name}-{n}", in: window)
                try await edit("rename.prefix", "QA-", in: window)
                try await edit("rename.suffix", "-done", in: window)
                try expect(files.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }, "preview does not move files")
                try await click("task.apply", in: window)
                try await click("task.confirm")
                _ = try await finishJobs()
                try expectEqual(try TextFile.read(directory.appendingPathComponent("QA-one-001-done.txt")), "file 0")
                try expectEqual(try TextFile.read(directory.appendingPathComponent("QA-two-002-done.txt")), "file 1")
            }
        }

        await runner.testAsync("GUI Smart Organize preview and confirmation perform real type grouping") {
            try await withDocumentFixture { directory in
                defer { cleanupFeatures() }
                let file = directory.appendingPathComponent("photo.png")
                try ImageIOBridge.write(SampleMedia.image(width: 80, height: 60, hue: 0.2), to: file, format: .png)
                let window = FeatureWindows.shared.show("QA Organize") { TaskPanel(task: .smartOrganize, files: [file]) }
                try await click("task.apply", in: window)
                try await click("task.confirm")
                let outputs = try await finishJobs()
                try expectEqual(outputs.first?.deletingLastPathComponent().lastPathComponent, "Image")
                try expect(!FileManager.default.fileExists(atPath: file.path), "confirmed move")
                if let output = outputs.first { try await OutputValidator.validate(output, as: .png) }
            }
        }

        await runner.testAsync("GUI Batch Optimize runs preset work and displays per-file size and failure reports") {
            try await withDocumentFixture { directory in
                defer { cleanupFeatures() }
                let first = directory.appendingPathComponent("valid.png"), bad = directory.appendingPathComponent("broken.png")
                try ImageIOBridge.write(SampleMedia.image(width: 320, height: 160, hue: 0.1), to: first, format: .png)
                try Data("invalid image".utf8).write(to: bad)
                let window = FeatureWindows.shared.show("QA Optimize") { TaskPanel(task: .batchOptimize, files: [first, bad]) }
                try await click("Strong", in: window)
                try await click("task.apply", in: window)
                try await click("task.confirm")
                let outputs = try await finishJobs()
                try expectEqual(outputs.count, 1)
                try await wait("optimization report") {
                    let text = window.contentView.map { elements($0).map(\.text).joined(separator: " ") } ?? ""
                    return text.contains("valid.png") && text.contains("broken.png") && text.contains("→")
                }
                try expect(FileManager.default.fileExists(atPath: first.path), "source retained")
            }
        }

        await runner.testAsync("GUI PDF Password enforces authorization protects output and reports a wrong password") {
            try await withDocumentFixture { directory in
                defer { cleanupFeatures() }
                let pdf = directory.appendingPathComponent("document.pdf")
                try TextRenderer.writePDF("GUI password text", to: pdf)
                ToolWindowManager.shared.open(.pdfPassword, files: [pdf])
                guard let window = ToolWindowManager.shared.openWindows.first else { throw TestFailure(description: "password window") }
                try await edit("pdf.newPassword", "GUI-password", in: window)
                try expect(try await control("tool.save", in: window).enabled == false, "authorization required")
                try await click("pdf.authorized", in: window)
                try await click("tool.save", in: window)
                let outputs = try await finishJobs()
                guard let locked = outputs.first else { throw TestFailure(description: "protected PDF missing") }
                try expect(PDFDocument(url: locked)?.isLocked == true, "encrypted output")
                cleanupFeatures()
                ToolWindowManager.shared.open(.pdfPassword, files: [locked])
                guard let unlock = ToolWindowManager.shared.openWindows.first else { throw TestFailure(description: "unlock window") }
                try await edit("pdf.currentPassword", "wrong", in: unlock)
                try await click("pdf.protect", in: unlock)
                try await click("pdf.authorized", in: unlock)
                try await click("tool.save", in: unlock)
                let jobs = try await jobFailures()
                try expect(
                    jobs.contains {
                        if case .failed = $0.status { return true }; return false
                    }, "wrong password visible in job")
                cleanupFeatures()
                ToolWindowManager.shared.open(.pdfPassword, files: [locked])
                guard let valid = ToolWindowManager.shared.openWindows.first else { throw TestFailure(description: "retry window") }
                try await edit("pdf.currentPassword", "GUI-password", in: valid)
                try await click("pdf.protect", in: valid)
                try await click("pdf.authorized", in: valid)
                try await click("tool.save", in: valid)
                let unlocked = try await finishJobs()
                guard let final = unlocked.first else { throw TestFailure(description: "unprotected output") }
                try expect(PDFDocument(url: final)?.isEncrypted == false, "removed protection")
            }
        }

        await runner.testAsync("GUI visual PDF signature chooses an image page and exports a valid preserved-source copy") {
            try await withDocumentFixture { directory in
                defer { cleanupFeatures() }
                let pdf = directory.appendingPathComponent("two-pages.pdf"), signature = directory.appendingPathComponent("signature.png")
                let image = SampleMedia.image(width: 320, height: 160, hue: 0.2)
                try ImageIOBridge.writePDF(images: [image, image], to: pdf)
                let original = try Data(contentsOf: pdf)
                try ImageIOBridge.write(image, to: signature, format: .png)
                ValidationRuntime.fileSelections = [[signature]]
                ToolWindowManager.shared.open(.pdfSign, files: [pdf])
                guard let window = ToolWindowManager.shared.openWindows.first else { throw TestFailure(description: "signature window") }
                try await click("Choose signature image…", in: window)
                try await edit("Page", "2", in: window)
                _ = try await control("signature.preview", in: window)
                try await click("tool.save", in: window)
                let outputs = try await finishJobs()
                guard let signed = outputs.first else { throw TestFailure(description: "signature export") }
                try expectEqual(PDFDocument(url: signed)?.pageCount, 2)
                try expectEqual(try Data(contentsOf: pdf), original)
                try expect(ValidationRuntime.fileSelections.isEmpty, "image chooser response consumed")
            }
        }

        await runner.testAsync("GUI Remove Background exports a transparent image from the real app-icon fixture") {
            try await withDocumentFixture { directory in
                defer { cleanupFeatures() }
                let source = directory.appendingPathComponent("subject.png")
                let icon = URL(fileURLWithPath: "Assets.xcassets/AppIcon.appiconset/icon_512x512@1x.png")
                try FileManager.default.copyItem(at: icon, to: source)
                let original = try Data(contentsOf: source)
                ToolWindowManager.shared.open(.removeBackground, files: [source])
                guard let window = ToolWindowManager.shared.openWindows.first else { throw TestFailure(description: "foreground window") }
                try await click("tool.save", in: window)
                let outputs = try await finishJobs()
                guard let output = outputs.first else { throw TestFailure(description: "foreground output") }
                try await OutputValidator.validate(output, as: .png)
                try expectEqual(try Data(contentsOf: source), original)
                let image = try ImageIOBridge.load(output)
                try expect(image.alphaInfo != .none && image.alphaInfo != .noneSkipFirst && image.alphaInfo != .noneSkipLast, "PNG has alpha")
            }
        }

        await runner.testAsync("GUI radial exports ICO ICNS HTML PDF SVG clipping JSON YAML and XML through actual picker actions") {
            try await withDocumentFixture { directory in
                defer { cleanupFeatures() }
                let image = directory.appendingPathComponent("image.png")
                try ImageIOBridge.write(SampleMedia.image(width: 80, height: 60, hue: 0.2), to: image, format: .png)
                let html = directory.appendingPathComponent("page.html")
                try "<html><body><h1>Yuzu GUI</h1><p>Local &amp; valid</p></body></html>".write(to: html, atomically: false, encoding: .utf8)
                let json = directory.appendingPathComponent("settings.json")
                try "{\"name\":\"Yuzu\",\"enabled\":true}".write(to: json, atomically: false, encoding: .utf8)
                let clipping = directory.appendingPathComponent("sample.textClipping")
                try PropertyListSerialization.data(
                    fromPropertyList: ["UTI-Data": ["public.utf8-plain-text": Data("Yuzu clipping GUI".utf8)]], format: .binary, options: 0
                ).write(to: clipping)
                let pdf = directory.appendingPathComponent("multi.pdf")
                let frame = SampleMedia.image(width: 120, height: 80, hue: 0.1)
                try ImageIOBridge.writePDF(images: [frame, frame], to: pdf)
                let cases: [(URL, FileFormat)] = [
                    (image, .ico), (image, .icns), (html, .pdf), (html, .docx), (html, .txt), (pdf, .svg), (clipping, .txt), (clipping, .md), (clipping, .pdf),
                    (json, .yaml), (json, .xml),
                ]
                for (source, target) in cases {
                    cleanupFeatures()
                    try await choose(.convert(target), files: [source])
                    let outputs = try await finishJobs()
                    guard let output = outputs.first else { throw TestFailure(description: "radial output missing for \(target)") }
                    try await OutputValidator.validate(output, as: target)
                    if [.ico, .icns].contains(target) {
                        guard let icon = NSImage(contentsOf: output) else { throw TestFailure(description: "AppKit icon reader") }
                        let destination = directory.appendingPathComponent("custom-icon-\(target.rawValue).txt")
                        try Data("icon destination".utf8).write(to: destination)
                        try expect(NSWorkspace.shared.setIcon(icon, forFile: destination.path, options: []), "Finder accepts exported custom icon")
                        try expectEqual(try TextFile.read(destination), "icon destination")
                    }
                    if [.yaml, .xml].contains(target) {
                        cleanupFeatures()
                        try await choose(.convert(.json), files: [output])
                        guard let back = try await finishJobs().first else { throw TestFailure(description: "reverse structured conversion") }
                        let actual = try JSONSerialization.jsonObject(with: Data(contentsOf: back)) as? NSDictionary
                        let expected = try JSONSerialization.jsonObject(with: Data(contentsOf: json)) as? NSDictionary
                        try expectEqual(actual, expected)
                    }
                }
            }
        }

        await runner.testAsync("GUI Animated GIF configures frame timing exports animation and radial converts it and video to WebP") {
            try await withDocumentFixture { directory in
                defer { cleanupFeatures() }
                let frames = ["first.png", "second.png"].map { directory.appendingPathComponent($0) }
                for (i, frame) in frames.enumerated() {
                    try ImageIOBridge.write(SampleMedia.image(width: 160, height: 120, hue: Double(i) * 0.4), to: frame, format: .png)
                }
                try await choose(.animatedGIF, files: frames)
                guard let window = FeatureWindows.shared.openWindows.first(where: \.isVisible) else { throw TestFailure(description: "GIF panel") }
                if let slider = window.contentView.flatMap({ elements($0).first { $0.role == "AXSlider" } }) { try slider.set(NSNumber(value: 0.12)) }
                try await click("gif.up.1", in: window)
                try await click("Create GIF", in: window)
                guard let gif = try await finishJobs().first else { throw TestFailure(description: "GIF output") }
                guard let source = CGImageSourceCreateWithURL(gif as CFURL, nil) else { throw TestFailure(description: "GIF parse") }
                try expectEqual(CGImageSourceGetCount(source), 2)
                let timing = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
                try expect(abs((timing?[kCGImagePropertyGIFDelayTime] as? Double ?? 0) - 0.12) < 0.02, "configured frame timing survives export")
                guard let first = CGImageSourceCreateImageAtIndex(source, 0, nil),
                    let expected = NSBitmapImageRep(cgImage: try ImageIOBridge.load(frames[1])).colorAt(x: 4, y: 4)?.usingColorSpace(.deviceRGB),
                    let actual = NSBitmapImageRep(cgImage: first).colorAt(x: 4, y: 4)?.usingColorSpace(.deviceRGB)
                else { throw TestFailure(description: "GIF playback frame decode") }
                try expect(
                    abs(actual.redComponent - expected.redComponent) < 0.12 && abs(actual.greenComponent - expected.greenComponent) < 0.12,
                    "exported animation starts with reordered second image")
                let playback = NSBitmapImageRep(data: try Data(contentsOf: gif))
                playback?.setProperty(.currentFrame, withValue: 1)
                try expectEqual((playback?.value(forProperty: .currentFrame) as? NSNumber)?.intValue, 1, "AppKit playback advances to second frame")
                cleanupFeatures()
                try await choose(.convert(.webp), files: [gif])
                guard let webp = try await finishJobs().first else { throw TestFailure(description: "animated WebP") }
                try expect(try NativeWebPAnimation.validate(webp), "decoded animation")
                cleanupFeatures()
                let video = directory.appendingPathComponent("video.mp4")
                try await SampleMedia.writeVideo(to: video, seconds: 0.3, hue: 0.2)
                try await choose(.convert(.webp), files: [video])
                guard let animated = try await finishJobs().first else { throw TestFailure(description: "video animation") }
                try expect(try NativeWebPAnimation.validate(animated), "video WebP decoded")
            }
        }
    }
}
