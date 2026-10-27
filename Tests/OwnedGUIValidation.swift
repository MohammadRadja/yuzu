import AppKit
import ApplicationServices
import Foundation
import PDFKit
import SwiftUI

/// Acts only on accessibility objects reached from windows in this process.
/// No global key/mouse events, frontmost-window lookup, or external close action.
@MainActor
enum OwnedGUIValidation {
    final class Element {
        let object: NSObject
        init(_ object: NSObject) { self.object = object }
        func value(_ key: String) -> Any? {
            let selector = NSSelectorFromString(key)
            if object.responds(to: selector), let result = object.perform(selector)?.takeUnretainedValue() { return result }
            let legacy = NSSelectorFromString("accessibilityAttributeValue:")
            let names = [
                "accessibilityRole": "AXRole", "accessibilityChildren": "AXChildren", "accessibilityValue": "AXValue", "accessibilityLabel": "AXDescription",
                "accessibilityTitle": "AXTitle", "accessibilityIdentifier": "AXIdentifier", "accessibilityParent": "AXParent",
            ]
            guard let name = names[key], object.responds(to: legacy) else { return nil }
            return object.perform(legacy, with: name as NSString)?.takeUnretainedValue()
        }
        var id: String { value("accessibilityIdentifier") as? String ?? "" }
        var label: String { value("accessibilityLabel") as? String ?? "" }
        var title: String { value("accessibilityTitle") as? String ?? "" }
        var text: String { [label, title, value("accessibilityValue").map(String.init(describing:)) ?? ""].joined(separator: " ") }
        var role: String { value("accessibilityRole") as? String ?? "" }
        func press() throws {
            let selector = NSSelectorFromString("accessibilityPerformPress")
            guard object.responds(to: selector) else { throw TestFailure(description: "Control has no press action: \(id) \(text)") }
            typealias Press = @convention(c) (AnyObject, Selector) -> Bool
            let action = unsafeBitCast(object.method(for: selector), to: Press.self)
            let previous = (value("accessibilityValue") as? NSNumber)?.boolValue
            if !action(object, selector), role == "AXRadioButton" || role == "AXCheckBox" {
                let after = (value("accessibilityValue") as? NSNumber)?.boolValue
                if previous == after { try set(NSNumber(value: role == "AXRadioButton" ? true : !(previous ?? false))) }
            }
        }
        func set(_ value: AnyObject) throws {
            let selector = NSSelectorFromString("setAccessibilityValue:")
            guard object.responds(to: selector) else { throw TestFailure(description: "Control is not editable: \(id) \(text)") }
            typealias SetValue = @convention(c) (AnyObject, Selector, AnyObject) -> Void
            unsafeBitCast(object.method(for: selector), to: SetValue.self)(object, selector, value)
        }
        var enabled: Bool {
            let selector = NSSelectorFromString("isAccessibilityEnabled")
            guard object.responds(to: selector) else { return true }
            typealias Get = @convention(c) (AnyObject, Selector) -> Bool
            return unsafeBitCast(object.method(for: selector), to: Get.self)(object, selector)
        }
    }

    static func elements(_ root: NSObject, depth: Int = 0) -> [Element] {
        var seen = Set<ObjectIdentifier>()
        func walk(_ object: NSObject, depth: Int) -> [Element] {
            guard depth < 40, seen.insert(ObjectIdentifier(object)).inserted else { return [] }
            let node = Element(object)
            var children = (node.value("accessibilityChildrenInNavigationOrder") ?? node.value("accessibilityChildren")) as? [NSObject] ?? []
            for key in ["accessibilityRows", "accessibilityVisibleRows", "accessibilityContents"] { children += node.value(key) as? [NSObject] ?? [] }
            if let view = object as? NSView { children += view.subviews }
            return [node] + children.flatMap { walk($0, depth: depth + 1) }
        }
        return walk(root, depth: depth)
    }

    static func allElements() -> [Element] {
        NSApp.windows.filter(\.isVisible).flatMap { window in
            window.contentView.map { elements($0) } ?? []
        }
    }

    static func serviceEvents() { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }

    static func wait(_ message: String, timeout: TimeInterval = 12, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            serviceEvents()
            for window in NSApp.windows where window.isVisible { window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded() }
            guard Date() < deadline else {
                throw TestFailure(
                    description: "GUI timeout: \(message). Visible controls: "
                        + allElements().map { "\(type(of: $0.object)):\($0.role):\($0.id):\($0.text)" }.joined(separator: " | ").prefix(5000))
            }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
    }

    static func control(_ query: String, in window: NSWindow? = nil) async throws -> Element {
        func match() -> Element? {
            let nodes = window?.contentView.map { elements($0) } ?? allElements()
            return nodes.first { $0.id == query || $0.label == query || $0.title == query }
        }
        try await wait(query) { match() != nil }
        guard let result = match() else { throw TestFailure(description: "Control disappeared: \(query)") }
        return result
    }

    static func click(_ query: String, in window: NSWindow? = nil) async throws {
        _ = try await control(query, in: window)
        try await wait("enabled " + query) {
            let nodes = window?.contentView.map { elements($0) } ?? allElements()
            return nodes.first { $0.id == query || $0.label == query || $0.title == query }?.enabled == true
        }
        try await control(query, in: window).press()
        try await Task.sleep(nanoseconds: 80_000_000)
    }

    static func edit(_ query: String, _ text: String, in window: NSWindow? = nil) async throws {
        let node = try await control(query, in: window)
        try node.set(text as NSString)
        if let field = (node.object as? NSTextField) ?? (node.object as? NSCell)?.controlView as? NSTextField {
            field.stringValue = text
            field.currentEditor()?.string = text
            field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
            field.delegate?.controlTextDidEndEditing?(Notification(name: NSControl.textDidEndEditingNotification, object: field))
            if let action = field.action { field.sendAction(action, to: field.target) }
        }
        try await Task.sleep(nanoseconds: 80_000_000)
    }

    static func finishJobs() async throws -> [URL] {
        try await wait("job submission") { !JobRunner.shared.jobs.isEmpty }
        let jobs = JobRunner.shared.jobs
        try await wait("job completion", timeout: 120) { jobs.allSatisfy { $0.status.isFinished } }
        for job in jobs {
            if case .failed(let message) = job.status { throw TestFailure(description: "GUI operation failed: \(message)") }
        }
        return jobs.flatMap(\.outputs)
    }

    static func cleanup() {
        FeatureWindows.shared.closeAll()
        ToolWindowManager.shared.closeAll()
        JobRunner.shared.cancelAll()
        ValidationRuntime.fileSelections = []
        ValidationRuntime.revealedSelections = []
    }

    static func register(_ runner: TestRunner) async {
        guard let defaults = ValidationRuntime.isolatedDefaults else {
            fputs("Owned GUI validation requires an isolated YuzuQA defaults suite\n", stderr); exit(2)
        }
        defaults.set(false, forKey: "revealInFinder")
        defaults.set(false, forKey: "radialSoundEnabled")
        defaults.set("besideOriginal", forKey: "outputLocation")
        NSApplication.shared.setActivationPolicy(.accessory)
        // Register a public accessibility client for this process only. This
        // makes SwiftUI materialize its lazy accessibility nodes without VoiceOver.
        DispatchQueue.global().async {
            let application = AXUIElementCreateApplication(getpid())
            var children: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(application, kAXChildrenAttribute as CFString, &children)
        }
        _ = await RuntimeCapabilities.refresh()
        print("Owned GUI QA: nonactivating process-owned windows; file dialog responses supplied by fixture adapter; no global input events.")
        if let filter = ProcessInfo.processInfo.environment["YUZU_GUI_CASE"] { print("Case filter: " + filter) }
        defer { cleanup() }

        await runner.testAsync("GUI OCR and watermark integration preserves the original scanned PDF fixture") {
            try await withDocumentFixture { directory in
                var phase = "image watermark"
                do {
                    let png = directory.appendingPathComponent("source.png")
                    let image = SampleMedia.image(width: 640, height: 320, hue: 0.1)
                    try ImageIOBridge.write(image, to: png, format: .png)
                    var options = WatermarkOptions()
                    options.text = "COPY"; options.opacity = 1; options.rotation = 25
                    let output = directory.appendingPathComponent("watermarked.png")
                    try await WatermarkOps.export(png, to: output, options: options, progress: { _ in })
                    try await OutputValidator.validate(output, as: .png)
                    try expect(try Data(contentsOf: png) != Data(contentsOf: output), "watermark changes pixels")
                    let pdf = directory.appendingPathComponent("scan.pdf")
                    try ImageIOBridge.writePDF(images: [image], to: pdf)
                    let markedPDF = directory.appendingPathComponent("watermarked.pdf")
                    try await WatermarkOps.export(pdf, to: markedPDF, options: options, progress: { _ in })
                    try expectEqual(PDFDocument(url: markedPDF)?.pageCount, 1)
                    phase = "scanned PDF recognition"
                    let text = try await OCROps.text(pdf, progress: { _ in })
                    try expect(text.localizedCaseInsensitiveContains("Yuzu"), "Vision recognized actual rendered text: \(text)")
                    let txt = directory.appendingPathComponent("OCR.txt")
                    phase = "scanned PDF text export"
                    try await OCROps.export(pdf, to: txt, progress: { _ in })
                    try expect(try String(contentsOf: txt, encoding: .utf8).localizedCaseInsensitiveContains("Yuzu"), "OCR exported valid text")
                } catch {
                    let detail = error as NSError
                    throw TestFailure(description: "\(phase): \(String(reflecting: error)); \(detail.domain) code \(detail.code); \(detail.userInfo)")
                }
            }
        }

        await runner.testAsync("GUI ZIP button commits valid output closes its own panel and dismisses completed progress") {
            try await withDocumentFixture { directory in
                defer { cleanup() }
                let source = directory.appendingPathComponent("source.txt")
                try Data("GUI zip".utf8).write(to: source)
                let window = FeatureWindows.shared.show("QA ZIP") { ArchiveActionView(files: [source], creating: true) }
                try await click("Create ZIP", in: window)
                let outputs = try await finishJobs()
                try expectEqual(outputs.count, 1)
                guard let zip = outputs.first else { throw TestFailure(description: "ZIP missing") }
                try await OutputValidator.validate(zip, as: .zip)
                try await wait("archive panel closes") { !window.isVisible }
                try await wait("completed progress dismisses", timeout: 5) { JobRunner.shared.jobs.isEmpty }
                try expect(!NSApp.windows.contains { ($0 is JobHUDPanel || $0 is JobPillPanel) && $0.isVisible }, "HUD hidden")
                try expectEqual(try TextFile.read(source), "GUI zip")
                try expect(NSWorkspace.shared.frontmostApplication?.processIdentifier != getpid(), "QA never activated")
            }
        }

        await runner.testAsync("GUI Inspect shows file folder metadata and a missing-file error") {
            try await withDocumentFixture { directory in
                defer { cleanup() }
                let source = directory.appendingPathComponent("metadata.txt")
                try Data("Yuzu".utf8).write(to: source)
                let missing = directory.appendingPathComponent("gone.txt")
                let window = FeatureWindows.shared.show("QA Inspect") { FileInspectView(files: [source, directory, missing]) }
                try await wait("native inspection rows") {
                    let text = window.contentView.map { elements($0).map(\.text).joined(separator: " ") } ?? ""
                    return text.contains("metadata.txt") && text.contains("Permissions:") && text.contains("gone.txt") && text.contains("Size:")
                }
                let text = window.contentView.map { elements($0).map(\.text).joined(separator: " ") } ?? ""
                try expect(
                    text.contains("doesn’t exist") || text.contains("does not exist") || text.contains("couldn’t") || text.contains("could not"),
                    "missing file error shown")
            }
        }

        for tool: ToolID in [.ocr, .upscaleImage, .watermark, .fileComparison] {
            await runner.testAsync("GUI \(tool.title) actual controls export or compare fixture content") {
                try await withDocumentFixture { directory in
                    defer { cleanup() }
                    let first = directory.appendingPathComponent("photo.png"), second = directory.appendingPathComponent("other.png")
                    try ImageIOBridge.write(SampleMedia.image(width: 640, height: 320, hue: 0.2), to: first, format: .png)
                    try FileManager.default.copyItem(at: first, to: second)
                    ToolWindowManager.shared.open(tool, files: tool == .fileComparison ? [first, second] : [first])
                    guard let window = ToolWindowManager.shared.openWindows.first else { throw TestFailure(description: "Tool window missing") }
                    if tool == .fileComparison {
                        try await wait("comparison result") {
                            window.contentView.map { elements($0).contains { $0.text.contains("identical SHA-256") } } == true
                        }
                        try await click("tool.save", in: window)
                    } else {
                        if tool == .watermark { try await edit("watermark.text", "QA watermark", in: window) }
                        if tool == .upscaleImage { try await click("4×", in: window) }
                        try await click("tool.save", in: window)
                        let outputs = try await finishJobs()
                        guard let output = outputs.first else { throw TestFailure(description: "Tool export missing") }
                        try await OutputValidator.validate(output, as: tool == .ocr ? .txt : .png)
                        if tool == .ocr { try expect(try TextFile.read(output).localizedCaseInsensitiveContains("Yuzu"), "TXT recognized text") }
                        if tool == .upscaleImage { try expectEqual(ImageIOBridge.pixelSize(output), CGSize(width: 2560, height: 1280)) }
                    }
                    try expect(!window.isVisible, "production tool save/close flow")
                }
            }
        }
        await registerFeatures(runner)
        await registerAdditionalFeatures(runner)
        await registerCancellationCases(runner)
        await registerCompatibilityCases(runner)
    }
}
