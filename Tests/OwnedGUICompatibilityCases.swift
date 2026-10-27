import AppKit
import Foundation
import ImageIO
import PDFKit

@MainActor
extension OwnedGUIValidation {
    static func registerCompatibilityCases(_ runner: TestRunner) async {
        await runner.testAsync("GUI HTML radial exports all targets from Unicode tables malformed markup and offline-resource fixtures") {
            try await withDocumentFixture { directory in
                defer { cleanupFeatures() }
                let variants = [
                    "<html><head><script>SHOULD_NOT_EXPORT</script><style>SECRET_STYLE</style></head><body><h1>Résumé 日本語</h1><p>Yuzu &amp; local</p></body></html>",
                    "<html><body><table><tr><td>Yuzu</td><td>42</td></tr></table><ul><li>Alpha</li><li>Beta</li></ul></body></html>",
                    "<html><body><h1>Yuzu broken<p>Still visible<br>Second line<img src='file:///nonexistent/yuzu-qa.png'><iframe src='https://example.invalid/'>SHOULD_NOT_EXPORT</iframe></body>",
                ]
                for (index, markup) in variants.enumerated() {
                    let source = directory.appendingPathComponent("variant-\(index).html")
                    try Data(markup.utf8).write(to: source)
                    for target: FileFormat in [.pdf, .docx, .txt] {
                        cleanupFeatures()
                        try await choose(.convert(target), files: [source])
                        guard let output = try await finishJobs().first else { throw TestFailure(description: "HTML output") }
                        try await OutputValidator.validate(output, as: target)
                        let text: String
                        if target == .pdf {
                            text = PDFDocument(url: output)?.string ?? ""
                        } else if target == .docx {
                            let archive = try await DocumentArchive.open(output)
                            let document = try XMLDocument(xmlString: try await archive.text("word/document.xml"), options: [.nodeLoadExternalEntitiesNever])
                            text = document.rootElement()?.stringValue ?? ""
                        } else {
                            text = try TextFile.read(output)
                        }
                        try expect(text.contains("Yuzu"), "visible HTML content survives \(target)")
                        try expect(!text.contains("SHOULD_NOT_EXPORT") && !text.contains("SECRET_STYLE"), "inactive content omitted")
                    }
                    try expectEqual(try Data(contentsOf: source), Data(markup.utf8))
                }
            }
        }

        await runner.testAsync("GUI PDF to SVG exports distinct pages that the native Quick Look renderer displays") {
            try await withDocumentFixture { directory in
                defer { cleanupFeatures() }
                let source = directory.appendingPathComponent("pages.pdf")
                try ImageIOBridge.writePDF(
                    images: [SampleMedia.image(width: 160, height: 80, hue: 0.1), SampleMedia.image(width: 160, height: 80, hue: 0.7)], to: source)
                let original = try Data(contentsOf: source)
                try await choose(.convert(.svg), files: [source])
                guard let folder = try await finishJobs().first else { throw TestFailure(description: "SVG output directory") }
                var thumbnails: [Data] = []
                for index in 1...2 {
                    let page = folder.appendingPathComponent("page-\(index).svg")
                    let result = try await Shell.run("/usr/bin/qlmanage", ["-t", "-s", "320", "-o", directory.path, page.path])
                    try expect(result.succeeded, "Quick Look SVG renderer: \(result.stderr)")
                    let thumbnail = directory.appendingPathComponent(page.lastPathComponent + ".png")
                    let image = try ImageIOBridge.load(thumbnail)
                    let bitmap = NSBitmapImageRep(cgImage: image)
                    var minX = image.width, minY = image.height, maxX = -1, maxY = -1
                    for y in 0..<image.height {
                        for x in 0..<image.width {
                            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.alphaComponent > 0.5 else { continue }
                            let channels = [color.redComponent, color.greenComponent, color.blueComponent]
                            if (channels.max() ?? 0) - (channels.min() ?? 0) > 0.12 {
                                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                            }
                        }
                    }
                    let ratio = Double(maxX - minX + 1) / Double(max(1, maxY - minY + 1))
                    try expect(
                        maxX > minX && (1.7...2.3).contains(ratio),
                        "Quick Look's square thumbnail contains the landscape page; colored aspect \(ratio), thumbnail \(image.width)x\(image.height)")
                    thumbnails.append(try Data(contentsOf: thumbnail))
                }
                try expect(thumbnails[0] != thumbnails[1], "SVG reader displays the distinct page content")
                try expectEqual(try Data(contentsOf: source), original)
            }
        }

        await runner.testAsync("GUI radial converts nested YAML configuration and mixed-content XML both ways without losing data") {
            try await withDocumentFixture { directory in
                defer { cleanupFeatures() }
                let yaml = directory.appendingPathComponent("config.yaml")
                try Data(
                    "name: Yuzu\nenabled: true\nworkers: 2\npaths:\n  - '/tmp/first file'\n  - '/tmp/ü'\noptions:\n  quality: 0.8\n  optional: null\n".utf8
                ).write(to: yaml)
                let xml = directory.appendingPathComponent("document.xml")
                try Data("<catalog lang=\"id\">Lead<item id=\"1\">Yuzu &amp; citrus</item><!-- keep --><item id=\"2\">日本語</item>Tail</catalog>".utf8).write(
                    to: xml)
                for (source, target) in [(yaml, FileFormat.yaml), (xml, FileFormat.xml)] {
                    cleanupFeatures()
                    try await choose(.convert(.json), files: [source])
                    guard let json = try await finishJobs().first else { throw TestFailure(description: "structured JSON") }
                    let expected = try JSONSerialization.jsonObject(with: Data(contentsOf: json)) as? NSDictionary
                    cleanupFeatures(); try await choose(.convert(target), files: [json])
                    guard let restored = try await finishJobs().first else { throw TestFailure(description: "structured reverse") }
                    if target == .yaml {
                        let actual = try YAMLDocument.read(TextFile.read(restored)) as? NSDictionary
                        try expectEqual(actual, expected, "nested configuration round trip")
                    } else {
                        let document = try XMLDocument(contentsOf: restored, options: [.nodeLoadExternalEntitiesNever])
                        try expectEqual(document.rootElement()?.attribute(forName: "lang")?.stringValue, "id")
                        try expectEqual(document.rootElement()?.elements(forName: "item").count, 2)
                        let text = try TextFile.read(restored)
                        try expect(
                            text.contains("Lead") && text.contains("Tail") && text.contains("日本語"), "XML ordered text content retained")
                    }
                }
            }
        }

        await runner.testAsync("GUI radial fits all corners of the existing physical display without global mouse input") {
            try await withDocumentFixture { directory in
                defer { cleanupFeatures() }
                guard let screen = NSScreen.main else { throw TestFailure(description: "existing display unavailable") }
                let source = directory.appendingPathComponent("screen.png")
                try ImageIOBridge.write(SampleMedia.image(width: 80, height: 40, hue: 0.2), to: source, format: .png)
                let bounds = screen.visibleFrame
                for point in [
                    NSPoint(x: bounds.minX + 1, y: bounds.minY + 1), NSPoint(x: bounds.maxX - 1, y: bounds.maxY - 1),
                    NSPoint(x: bounds.minX + 1, y: bounds.maxY - 1), NSPoint(x: bounds.maxX - 1, y: bounds.minY + 1),
                ] {
                    cleanupFeatures()
                    let controller = RadialController(), monitor = DragMonitor()
                    PickerKeepers.shared.controllers.append(controller)
                    controller.dragMonitor(
                        monitor, didUpdate: DragSessionUpdate(id: UUID(), urls: [source], mode: .conversion, point: point, dragConfirmed: true))
                    try await wait("radial displayed on current monitor") { NSApp.windows.contains { $0 is RadialPanel && $0.isVisible } }
                    guard let panel = NSApp.windows.first(where: { $0 is RadialPanel && $0.isVisible }) else { throw TestFailure(description: "radial panel") }
                    try expect(bounds.insetBy(dx: -0.5, dy: -0.5).contains(panel.frame), "panel remains inside the current screen's visible bounds")
                    try expectEqual(panel.backingScaleFactor, screen.backingScaleFactor)
                }
                print("       physical display: \(Int(bounds.width))×\(Int(bounds.height)) points, scale \(screen.backingScaleFactor)")
            }
        }
    }
}
