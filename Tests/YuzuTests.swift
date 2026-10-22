import AppKit
import Foundation
import PDFKit
import SwiftUI

struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

final class TestRunner {
    private var failures: [String] = []
    private var count = 0

    func test(_ name: String, _ body: () throws -> Void) {
        count += 1
        do {
            try body()
            print("  ok   \(name)")
        } catch {
            failures.append("\(name): \(error)")
            print("  FAIL \(name): \(error)")
        }
    }

    func finish() -> Never {
        print("\n\(count - failures.count)/\(count) passed")
        exit(failures.isEmpty ? 0 : 1)
    }

    func testAsync(_ name: String, _ body: () async throws -> Void) async {
        count += 1
        do {
            try await body()
            print("  ok   \(name)")
        } catch {
            failures.append("\(name): \(error)")
            print("  FAIL \(name): \(error)")
        }
    }
}

func expect(_ condition: Bool, _ message: String, file: String = #fileID, line: Int = #line) throws {
    if !condition { throw TestFailure(description: "\(message) (\(file):\(line))") }
}

func expectEqual<T: Equatable>(_ a: T, _ b: T, _ message: String = "", file: String = #fileID, line: Int = #line) throws {
    if a != b { throw TestFailure(description: "\(message) expected \(b), got \(a) (\(file):\(line))") }
}

func withDocumentFixture(_ body: (URL) async throws -> Void) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("yuzu-document-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try await body(directory)
}

func convertFixture(_ source: URL, to target: FileFormat, in directory: URL) async throws -> URL {
    guard let format = FileFormat.detect(source) else { throw TestFailure(description: "Unknown fixture format") }
    return try await Engines.convert(
        ConversionRequest(
            source: source, sourceFormat: format, target: target, destination: ConversionMatrix.outputURL(for: source, target: target, in: directory),
            progress: { _ in }))
}

@main
@MainActor
struct YuzuTests {
    static func main() async {
        let runner = TestRunner()

        runner.test("conversion matrix has 253 options") {
            try expectEqual(ConversionMatrix.totalConversions, 253)
        }

        runner.test("25 advanced tools") {
            try expectEqual(ToolID.total, 25)
        }

        runner.test("no format converts to itself") {
            for format in FileFormat.allCases {
                try expect(!ConversionMatrix.targets(for: format).contains(format), "\(format) targets itself")
            }
        }

        runner.test("JPG and PNG export DOCX, other images do not") {
            try expect(ConversionMatrix.targets(for: .jpg).contains(.docx), "jpg → docx")
            try expect(ConversionMatrix.targets(for: .png).contains(.docx), "png → docx")
            try expect(!ConversionMatrix.targets(for: .webp).contains(.docx), "webp → docx")
            try expect(ConversionMatrix.targets(for: .svg).contains(.pdf), "svg → pdf")
        }

        runner.test("video exports GIF and MP3, GIF does not") {
            try expect(ConversionMatrix.targets(for: .mp4).contains(.gif), "mp4 → gif")
            try expect(ConversionMatrix.targets(for: .mp4).contains(.mp3), "mp4 → mp3")
            try expect(!ConversionMatrix.targets(for: .gif).contains(.mp3), "gif → mp3")
            try expectEqual(ConversionMatrix.targets(for: .gif), FileFormat.video)
        }

        runner.test("PDF, TXT, subtitle and archive targets") {
            try expectEqual(ConversionMatrix.targets(for: .pdf), [.docx, .pptx, .xlsx, .jpg, .png, .epub, .txt, .md])
            try expectEqual(ConversionMatrix.targets(for: .txt), [.pdf, .jpg, .png, .srt, .vtt, .docx, .md, .epub, .html])
            try expectEqual(ConversionMatrix.targets(for: .srt), [.vtt, .txt])
            try expectEqual(ConversionMatrix.targets(for: .zip), [.tar, .gz])
            try expectEqual(ConversionMatrix.targets(for: .docx), [.pdf, .md, .txt, .epub, .html])
        }

        runner.test("mixed selection intersects targets") {
            try expectEqual(ConversionMatrix.targets(for: [.jpg, .webp]), [.png, .heic, .tiff, .avif, .bmp, .pdf])
            try expectEqual(ConversionMatrix.targets(for: [.jpg, .mp3]), [])
            try expectEqual(ConversionMatrix.targets(for: []), [])
        }

        runner.test("format detection from extension and aliases") {
            try expectEqual(FileFormat.detect(URL(fileURLWithPath: "/tmp/Photo.JPEG")), .jpg)
            try expectEqual(FileFormat.detect(URL(fileURLWithPath: "/tmp/a.tif")), .tiff)
            try expectEqual(FileFormat.detect(URL(fileURLWithPath: "/tmp/a.tgz")), .gz)
            try expectEqual(FileFormat.detect(URL(fileURLWithPath: "/tmp/a.unknown")), nil)
            let added: [FileFormat] = [.ppt, .pptx, .xls, .xlsx, .ods, .csv, .tsv, .pages, .md, .epub, .rtf, .rtfd, .html]
            for format in added {
                try expectEqual(FileFormat.detect(URL(fileURLWithPath: "/tmp/File.\(format.rawValue.uppercased())")), format)
            }
            try expectEqual(FileFormat.detect(extension: "markdown"), .md)
            try expectEqual(FileFormat.pptx.category, .presentation)
            try expectEqual(FileFormat.xlsx.category, .spreadsheet)
        }

        runner.test("every advertised conversion has an engine and input-only types are never targets") {
            for source in FileFormat.allCases {
                let targets = ConversionMatrix.targets(for: source)
                try expectEqual(Set(targets).count, targets.count, "targets are unique")
                for target in targets {
                    try expect(Engines.engine(from: source, to: target) != nil, "missing engine for \(source) -> \(target)")
                    try expect(![FileFormat.ppt, .xls, .pages, .rtf, .rtfd, .rar].contains(target), "input-only target \(target)")
                }
            }
            try expect(ConversionMatrix.targets(for: .html).isEmpty, "HTML is export-only")
            try expectEqual(ConversionMatrix.targets(for: [.pptx, .pdf]), [.jpg, .png])
        }

        runner.test("CSV and TSV preserve quoting Unicode empty fields and embedded newlines") {
            let rows = [["Name", "Comment", "Code"], ["Yuzu 🍋", "line 1\r\nline 2, \"quoted\"", "0012"], ["", "=1+1", ""]]
            for separator: Character in [",", "\t"] {
                try expectEqual(DelimitedText.parse("\u{FEFF}" + DelimitedText.serialize(rows, separator: separator), separator: separator), rows)
            }
            try expectEqual(DelimitedText.parse("", separator: ","), [])
            try expectEqual(DelimitedText.parse("\"\"", separator: ","), [[""]])
            for invalid in ["\"unclosed", "\"closed\"junk", "unexpected\"quote", "\"" + String(repeating: "a", count: 32_768) + "\""] {
                do {
                    _ = try DelimitedText.parse(invalid, separator: ",")
                    throw TestFailure(description: "malformed CSV must be rejected")
                } catch is YuzuError {}
            }
        }

        runner.test("document XML rejects unsafe paths and DTDs and escapes control characters") {
            for path in ["../outside", "/absolute", "safe/../../outside", "safe\\outside", "https:remote", "safe/./file"] {
                do {
                    try DocumentPackage.validateEntry(path)
                    throw TestFailure(description: "unsafe package path accepted")
                } catch is YuzuError {}
            }
            do {
                _ = try DocumentXML.parse("<!DOCTYPE x [<!ENTITY e SYSTEM 'file:///etc/passwd'>]><x>&e;</x>")
                throw TestFailure(description: "external entity accepted")
            } catch is YuzuError {}
            try expectEqual(DocumentPackage.escape("<a>&\u{0}\""), "&lt;a&gt;&amp;&quot;")
        }

        runner.test("stripped base names") {
            try expectEqual(ConversionMatrix.strippedBaseName("archive.tar.gz"), "archive")
            try expectEqual(ConversionMatrix.strippedBaseName("archive.tgz"), "archive")
            try expectEqual(ConversionMatrix.strippedBaseName("my.photo.HEIC"), "my.photo")
            try expectEqual(ConversionMatrix.strippedBaseName(".hidden"), ".hidden")
            try expectEqual(ConversionMatrix.strippedBaseName("noext"), "noext")
        }

        runner.test("output naming avoids collisions") {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("yuzu-tests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let source = URL(fileURLWithPath: "/tmp/photo.heic")
            let first = ConversionMatrix.outputURL(for: source, target: .jpg, in: dir)
            try expectEqual(first.lastPathComponent, "photo.jpg")
            try Data().write(to: first)
            let second = ConversionMatrix.outputURL(for: source, target: .jpg, in: dir)
            try expectEqual(second.lastPathComponent, "photo 2.jpg")
            let third = ConversionMatrix.outputURL(for: source, target: .jpg, in: dir, existing: ["photo 2.jpg"])
            try expectEqual(third.lastPathComponent, "photo 3.jpg")
            let suffixed = ConversionMatrix.uniqueURL(directory: dir, baseName: "photo", suffix: "compressed", ext: "jpg")
            try expectEqual(suffixed.lastPathComponent, "photo compressed.jpg")
            try Data().write(to: suffixed)
            try expectEqual(
                ConversionMatrix.uniqueURL(directory: dir, baseName: "photo", suffix: "compressed", ext: "jpg").lastPathComponent, "photo compressed 2.jpg")
            try expectEqual(ConversionMatrix.uniqueURL(directory: dir, baseName: "photo", suffix: "", ext: "pdf").lastPathComponent, "photo.pdf")
            try FileManager.default.createDirectory(at: dir.appendingPathComponent("clip clips"), withIntermediateDirectories: true)
            try expectEqual(ConversionMatrix.uniqueDirectory(directory: dir, name: "clip clips").lastPathComponent, "clip clips 2")
        }

        runner.test("SRT parsing") {
            let srt = "1\n00:00:01,000 --> 00:00:02,500\nHello\nWorld\n\n2\n00:01:00,000 --> 00:01:03,250\n<i>Bye</i>\n"
            let cues = SubtitleParser.parse(srt, hint: .srt)
            try expectEqual(cues.count, 2)
            try expectEqual(cues[0].start, 1)
            try expectEqual(cues[0].end, 2.5)
            try expectEqual(cues[0].text, "Hello\nWorld")
            try expectEqual(cues[1].start, 60)
            try expectEqual(cues[1].end, 63.25)
        }

        runner.test("VTT parsing with header, notes and cue settings") {
            let vtt = "WEBVTT\nKind: captions\n\nNOTE comment\n\n00:01.000 --> 00:02.000 align:start\nFirst\n\n01:00:00.000 --> 01:00:01.000\nSecond\n"
            let cues = SubtitleParser.parse(vtt, hint: .vtt)
            try expectEqual(cues.count, 2)
            try expectEqual(cues[0].start, 1)
            try expectEqual(cues[0].end, 2)
            try expectEqual(cues[0].text, "First")
            try expectEqual(cues[1].start, 3600)
        }

        runner.test("subtitle serialization round trip") {
            let cues = [SubtitleCue(start: 0.5, end: 2, text: "A"), SubtitleCue(start: 3661.25, end: 3662, text: "B\nC")]
            let srt = SubtitleParser.serialize(cues, as: .srt)
            try expect(srt.hasPrefix("1\n00:00:00,500 --> 00:00:02,000\nA\n\n2\n01:01:01,250 --> 01:01:02,000\nB\nC\n"), "srt output: \(srt)")
            let vtt = SubtitleParser.serialize(cues, as: .vtt)
            try expect(vtt.hasPrefix("WEBVTT\n\n00:00:00.500 --> 00:00:02.000\nA\n\n"), "vtt output: \(vtt)")
            let back = SubtitleParser.parse(vtt, hint: .vtt)
            try expectEqual(back.count, 2)
            try expectEqual(back[1].start, 3661.25)
            try expectEqual(SubtitleParser.serialize([SubtitleCue(start: 0, end: 1, text: "<b>x</b> {\\an8}y")], as: .txt), "x y\n")
        }

        runner.test("plain text becomes timed cues") {
            let cues = SubtitleParser.plainTextCues("One two three\n\nFour five")
            try expectEqual(cues.count, 2)
            try expectEqual(cues[0].start, 0)
            try expect(cues[1].start == cues[0].end, "cues are contiguous")
            try expect(cues[0].end - cues[0].start >= 1.5, "minimum duration")
        }

        runner.test("timestamp parsing") {
            try expectEqual(SubtitleParser.parseTimestamp("00:00:01,500"), 1.5)
            try expectEqual(SubtitleParser.parseTimestamp("01:02.250"), 62.25)
            try expectEqual(SubtitleParser.parseTimestamp("5"), 5)
            try expectEqual(SubtitleParser.parseTimestamp("a:b"), nil)
            try expectEqual(TimeFormatter.parseClock("1:02.5"), 62.5)
            try expectEqual(TimeFormatter.clock(62.5), "1:02.50")
        }

        runner.test("PDF page range parsing") {
            try expectEqual(PDFOps.parseRanges("1-3, 5, 7-6, 12", pageCount: 10), [1...3, 5...5, 6...7])
            try expectEqual(PDFOps.parseRanges("-2, 8-", pageCount: 10), [1...2, 8...10])
            try expectEqual(PDFOps.parseRanges("abc", pageCount: 10), [])
        }

        runner.test("tool applicability") {
            try expect(ToolID.cropImage.applies(to: [.jpg]), "crop single image")
            try expect(!ToolID.cropImage.applies(to: [.jpg, .png]), "crop needs one image")
            try expect(ToolID.createCollage.applies(to: [.jpg, .heic]), "collage multiple images")
            try expect(!ToolID.createCollage.applies(to: [.jpg]), "collage needs two")
            try expect(ToolID.compress.applies(to: [.pdf, .pdf]), "compress pdfs")
            try expect(!ToolID.compress.applies(to: [.jpg, .mp4]), "mixed categories")
            try expect(!ToolID.trimVideo.applies(to: [.gif]), "gif is not trimmable")
            try expect(ToolID.compress.applies(to: [.gif]), "gif compress")
            try expect(!ToolID.mergePDF.applies(to: [.docx, .docx]), "docx merge")
            try expectEqual(ToolID.available(for: [.mp3]).count, 7)
            try expectEqual(ToolID.available(for: [.pdf]).count, 4)
        }

        runner.test("radial modes have unique default modifiers") {
            try expectEqual(RadialMode.allCases.count, 4)
            try expectEqual(Set(RadialMode.allCases.map(\.defaultModifier)).count, RadialMode.allCases.count)
            try expectEqual(RadialMode.conversion.defaultModifier, .shift)
            try expectEqual(RadialMode.tools.defaultModifier, .command)
            try expectEqual(RadialMode.actions.defaultModifier, .control)
            try expectEqual(RadialMode.flow.defaultModifier, .option)
            try expectEqual(RadialMode.conversion.title, "Convert")
            try expectEqual(RadialMode.tools.title, "Tools")
            try expectEqual(RadialMode.actions.title, "Actions")
            try expectEqual(RadialMode.flow.title, "Tasks")
        }

        runner.test("modifier resolver switches modes and retains the last mode on release") {
            let assignments = Dictionary(uniqueKeysWithValues: RadialMode.allCases.map { ($0, $0.defaultModifier) })
            var resolver = RadialModeResolver(assignments: assignments)
            try expectEqual(resolver.resolve(.shift), .conversion)
            try expectEqual(resolver.resolve([.shift, .command]), .tools)
            try expectEqual(resolver.resolve(.shift), .conversion)
            try expectEqual(resolver.resolve([]), .conversion)
            try expectEqual(resolver.resolve(.option), .flow)
            try expectEqual(resolver.resolve([.shift, .option]), .tools)
            try expect(resolver.usingLegacyAlias, "legacy Shift + Option alias is tracked")
            try expectEqual(resolver.resolve(.shift), .conversion)
        }

        runner.test("radial provider separates conversion, tools and actions") {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("yuzu-radial-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let image = directory.appendingPathComponent("sample.jpg")
            try Data([0]).write(to: image)

            let conversion = RadialProvider.content(for: [image], mode: .conversion)
            try expect(!conversion.items.isEmpty, "jpg conversion targets are available")
            try expect(
                conversion.items.allSatisfy {
                    if case .convert = $0.action { return true }
                    return false
                }, "conversion mode contains only conversion actions")

            let tools = RadialProvider.content(for: [image], mode: .tools)
            try expect(!tools.items.isEmpty, "jpg tools are available")
            try expect(
                tools.items.allSatisfy {
                    if case .tool = $0.action { return true }
                    return false
                }, "tools mode contains only tool actions")

            let actions = RadialProvider.content(for: [image, directory], mode: .actions)
            try expect(actions.items.contains { $0.action == .file(.copy) }, "copy supports files and folders")
            try expect(actions.items.contains { $0.action == .file(.copyPath) }, "copy path supports files and folders")
            try expect(actions.items.contains { $0.action == .file(.move) }, "move supports files and folders")

            let flow = RadialProvider.content(for: [image], mode: .flow)
            try expect(flow.items.contains { $0.action == .tool(.compress) }, "Flow optimize opens the compressor")
            try expect(flow.items.contains { $0.action == .file(.move) }, "Flow organize uses move")
            try expect(flow.items.contains { $0.action == .file(.rename) }, "Flow rename is available for one item")
        }

        runner.test("drag URL normalization preserves folders and order") {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("yuzu-drag-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let first = directory.appendingPathComponent("first.txt")
            let second = directory.appendingPathComponent("second.txt")
            try Data().write(to: first)
            try Data().write(to: second)
            let normalized = DragMonitor.normalizeURLs([second, directory, first, second, directory])
            try expectEqual(normalized, [second.standardizedFileURL, directory.standardizedFileURL, first.standardizedFileURL])
        }

        runner.test("radial hit testing reaches every visible wedge for one through sixteen items") {
            for count in 1...16 {
                let geometry = RadialGeometry(count: count)
                let rect = CGRect(x: -120, y: 80, width: geometry.canvasDiameter, height: geometry.canvasDiameter)
                for index in 0..<count {
                    let midpoint = geometry.midpoint(for: index, in: rect)
                    let offset = CGPoint(x: midpoint.x - rect.midX, y: midpoint.y - rect.midY)
                    try expectEqual(geometry.index(at: offset), index, "\(count) items, wedge \(index)")
                    try expect(WedgeShape(geometry: geometry, index: index).path(in: rect).contains(midpoint), "visible label is inside wedge \(index)")
                }
            }
        }

        runner.test("radial hit testing rejects hub, outside and segment gaps") {
            for count in 1...16 {
                let geometry = RadialGeometry(count: count)
                try expectEqual(geometry.index(at: .zero), nil, "\(count) items, hub")
                for index in 0..<count {
                    let (start, end) = geometry.angles(for: index)
                    let mid = (start + end) / 2
                    let hubPoint = CGPoint(x: cos(mid) * (geometry.innerRadius - 1), y: -sin(mid) * (geometry.innerRadius - 1))
                    let outsidePoint = CGPoint(x: cos(mid) * (geometry.outerRadius + 1), y: -sin(mid) * (geometry.outerRadius + 1))
                    try expectEqual(geometry.index(at: hubPoint), nil, "\(count) items, wedge \(index) inner edge")
                    try expectEqual(geometry.index(at: outsidePoint), nil, "\(count) items, wedge \(index) outer edge")
                    if count > 1 {
                        let radius = (geometry.innerRadius + geometry.outerRadius) / 2
                        let gapPoint = CGPoint(x: cos(start) * radius, y: -sin(start) * radius)
                        try expectEqual(geometry.index(at: gapPoint), nil, "\(count) items, gap before wedge \(index)")
                    }
                }
            }
            try expectEqual(RadialGeometry(count: 0).index(at: .zero), nil, "empty radial")
        }

        runner.test("single-item radial draws an annulus and keeps the hub non-actionable") {
            let geometry = RadialGeometry(count: 1)
            let rect = CGRect(x: 0, y: 0, width: geometry.canvasDiameter, height: geometry.canvasDiameter)
            let path = WedgeShape(geometry: geometry, index: 0).path(in: rect)
            let midpointRadius = (geometry.innerRadius + geometry.outerRadius) / 2
            try expectEqual(geometry.index(at: .zero), nil, "single-item hub")
            try expectEqual(geometry.index(at: CGPoint(x: midpointRadius, y: 0)), 0, "single-item wedge")
            try expectEqual(geometry.index(at: CGPoint(x: geometry.outerRadius + 1, y: 0)), nil, "single-item outside")
            try expect(!path.contains(CGPoint(x: rect.midX, y: rect.midY)), "drawn wedge must exclude center")
            try expect(!path.contains(CGPoint(x: rect.midX + geometry.innerRadius - 1, y: rect.midY)), "drawn wedge must exclude hub edge")
            try expect(path.contains(CGPoint(x: rect.midX + midpointRadius, y: rect.midY)), "drawn ring remains actionable")
        }

        runner.test("AppKit radial hit testing maps upper and lower wedges to their rendered positions") {
            _ = NSApplication.shared
            let view = RadialView(frame: CGRect(x: 0, y: 0, width: 500, height: 500))
            let centers = [NSPoint(x: 250, y: 250), NSPoint(x: -170, y: -95), NSPoint(x: 90, y: -250)]
            for count in 1...16 {
                view.items = Array(FileFormat.allCases.prefix(count)).map(RadialItem.init(format:))
                let geometry = RadialGeometry(count: count)
                let canvas = CGRect(x: 0, y: 0, width: geometry.canvasDiameter, height: geometry.canvasDiameter)
                for center in centers {
                    view.center = center
                    for index in 0..<count {
                        let midpoint = geometry.midpoint(for: index, in: canvas)
                        let appKitPoint = NSPoint(x: center.x + midpoint.x - canvas.midX, y: center.y - (midpoint.y - canvas.midY))
                        try expectEqual(view.index(at: appKitPoint), index, "AppKit \(count) items, wedge \(index), center \(center)")
                    }
                    try expectEqual(view.index(at: center), nil, "AppKit hub")
                }
            }
            view.items = Array(FileFormat.allCases.prefix(6)).map(RadialItem.init(format:))
            view.center = NSPoint(x: 250, y: 250)
            let radius = RadialGeometry(count: 6).labelRadius
            try expectEqual(view.index(at: NSPoint(x: 250, y: 250 + radius)), 0, "upper wedge is index zero in AppKit coordinates")
            try expectEqual(view.index(at: NSPoint(x: 250, y: 250 - radius)), 3, "lower wedge is opposite the upper wedge")
        }

        runner.test("screen and window drag coordinates reach the same wedge across negative origins") {
            _ = NSApplication.shared
            let window = NSWindow(
                contentRect: NSRect(x: -1600, y: -900, width: 640, height: 550),
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            defer { window.close() }
            let container = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 550))
            window.contentView = container
            let view = RadialView(frame: NSRect(x: 47, y: 39, width: 500, height: 450))
            container.addSubview(view)
            view.bounds.origin = NSPoint(x: -23, y: 37)
            view.center = NSPoint(x: view.bounds.midX, y: view.bounds.midY)
            view.items = Array(FileFormat.allCases.prefix(8)).map(RadialItem.init(format:))
            let geometry = RadialGeometry(count: view.items.count)
            let canvas = CGRect(x: 0, y: 0, width: geometry.canvasDiameter, height: geometry.canvasDiameter)
            for index in view.items.indices {
                let midpoint = geometry.midpoint(for: index, in: canvas)
                let localPoint = NSPoint(x: view.center.x + midpoint.x - canvas.midX, y: view.center.y - (midpoint.y - canvas.midY))
                let windowPoint = view.convert(localPoint, to: nil)
                view.updateHighlight(forWindowPoint: windowPoint)
                try expectEqual(view.highlighted, index, "window coordinate for wedge \(index)")
                view.clearHighlight()
                let screenPoint = window.convertPoint(toScreen: windowPoint)
                view.updateHighlight(forScreenPoint: screenPoint)
                try expectEqual(view.highlighted, index, "screen coordinate for wedge \(index)")
            }
            let hubScreenPoint = window.convertPoint(toScreen: view.convert(view.center, to: nil))
            view.updateHighlight(forScreenPoint: hubScreenPoint)
            try expectEqual(view.highlighted, nil, "entering hub clears the last screen-coordinate hover")
            let outside = NSPoint(x: view.center.x + geometry.outerRadius + 1, y: view.center.y)
            view.updateHighlight(forScreenPoint: window.convertPoint(toScreen: view.convert(outside, to: nil)))
            try expectEqual(view.highlighted, nil, "leaving ring clears screen-coordinate hover")
        }

        runner.test("radial item replacement clears stale highlight and rejects invalid indices") {
            _ = NSApplication.shared
            let view = RadialView(frame: NSRect(x: 0, y: 0, width: 500, height: 500))
            let conversions = [RadialItem(format: .png), RadialItem(format: .pdf)]
            view.items = conversions
            view.highlight(1)
            try expectEqual(view.highlighted, 1)
            view.items = conversions
            try expectEqual(view.highlighted, 1, "unchanged content preserves hover")
            view.items = [RadialItem(fileAction: .copy), RadialItem(fileAction: .move)]
            try expectEqual(view.highlighted, nil, "same-sized provider replacement invalidates selected action")
            view.highlight(-1)
            try expectEqual(view.highlighted, nil, "negative index is invalid")
            view.highlight(view.items.count)
            try expectEqual(view.highlighted, nil, "out-of-range index is invalid")
            view.highlight(0)
            view.items = []
            try expectEqual(view.highlighted, nil, "empty provider clears hover")
        }

        runner.test("radial placement stays inside display edges including negative screen origins") {
            let diameter = RadialGeometry(count: 6).canvasDiameter
            let screens = [
                NSRect(x: 0, y: 24, width: 1440, height: 876),
                NSRect(x: -1920, y: -1080, width: 1920, height: 1056),
                NSRect(x: 1440, y: -200, width: 1280, height: 1000),
            ]
            for screen in screens {
                let anchors = [
                    NSPoint(x: screen.midX, y: screen.midY),
                    NSPoint(x: screen.minX, y: screen.minY),
                    NSPoint(x: screen.minX, y: screen.maxY),
                    NSPoint(x: screen.maxX, y: screen.minY),
                    NSPoint(x: screen.maxX, y: screen.maxY),
                    NSPoint(x: screen.minX - 100, y: screen.maxY + 100),
                ]
                for anchor in anchors {
                    let frame = RadialPlacement.frame(anchoredAt: anchor, in: screen, diameter: diameter)
                    try expect(screen.contains(frame), "panel fits display \(screen) at anchor \(anchor)")
                    try expectEqual(frame.size, NSSize(width: diameter, height: diameter), "placement preserves point dimensions")
                }
                let center = NSPoint(x: screen.midX, y: screen.midY)
                let frame = RadialPlacement.frame(anchoredAt: center, in: screen, diameter: diameter)
                try expectEqual(NSPoint(x: frame.midX, y: frame.midY), center, "unclamped radial remains centered on anchor")
            }
            let smallScreen = NSRect(x: -240, y: -160, width: 200, height: 120)
            let frame = RadialPlacement.frame(anchoredAt: .zero, in: smallScreen, diameter: diameter)
            try expect(smallScreen.contains(frame), "oversized requested panel fits available display")
            try expectEqual(frame.size, NSSize(width: 120, height: 120), "panel preserves square shape when constrained")
        }

        runner.test("drag session follows presentation hover commit and completion exactly once") {
            var session = RadialDragSession()
            let id = UUID()
            let file = URL(fileURLWithPath: "/tmp/yuzu-session.png")
            try expectEqual(session.phase, .idle)
            try expect(session.begin(id: id, urls: [file]), "begin drag")
            try expectEqual(session.phase, .dragging)
            session.hover(0)
            try expectEqual(session.phase, .dragging, "hover waits for presentation")
            session.present()
            try expectEqual(session.phase, .radialPresented)
            try expect(session.bind(sequenceNumber: 17), "bind native drag")
            session.hover(0)
            session.hover(3)
            try expectEqual(session.phase, .hoveringWedge(3), "hover follows each wedge")
            try expect(session.commit(id: id, sequenceNumber: 17, index: 3), "valid release commits")
            try expectEqual(session.phase, .committing)
            try expect(!session.isActive, "committing stops hover updates")
            try expect(!session.commit(id: id, sequenceNumber: 17, index: 3), "duplicate destination callback cannot commit")
            try expect(!session.begin(id: UUID(), urls: [file]), "a committing action cannot be replaced")
            session.cancel()
            session.hover(1)
            try expectEqual(session.phase, .committing, "late cancellation and hover cannot undo a commit")
            session.complete()
            try expectEqual(session.phase, .completed)
            try expect(session.urls.isEmpty, "completion clears file URLs")
            try expectEqual(session.sequenceNumber, nil, "completion clears native drag sequence")
            try expectEqual(session.id, id, "completion retains identity to reject late callbacks")
            try expect(!session.commit(id: id, sequenceNumber: 17, index: 3), "completed action cannot repeat")
        }

        runner.test("drag session rejects stale identities sequences and invalid targets") {
            var session = RadialDragSession()
            let id = UUID()
            session.begin(id: id, urls: [URL(fileURLWithPath: "/tmp/yuzu-session.png")])
            session.present()
            session.hover(2)
            try expect(!session.commit(id: id, sequenceNumber: 17, index: 2), "unbound native drag cannot commit")
            try expect(session.bind(sequenceNumber: 17), "first native sequence is accepted")
            try expect(session.bind(sequenceNumber: 17), "repeated native update is accepted")
            try expect(!session.bind(sequenceNumber: 18), "different native drag cannot replace binding")
            try expect(!session.commit(id: UUID(), sequenceNumber: 17, index: 2), "wrong session cannot commit")
            try expect(!session.commit(id: id, sequenceNumber: 18, index: 2), "wrong native sequence cannot commit")
            try expect(!session.commit(id: id, sequenceNumber: 17, index: 1), "stale selected wedge cannot commit")
            session.hover(-1)
            try expect(!session.commit(id: id, sequenceNumber: 17, index: -1), "negative target cannot commit")
            session.hover(nil)
            try expect(!session.commit(id: id, sequenceNumber: 17, index: 2), "release outside cannot commit")
            session.cancel()
            try expectEqual(session.phase, .cancelled, "outside release cancels")
        }

        runner.test("drag URL changes and cleared hover require a fresh target before committing") {
            var session = RadialDragSession()
            let id = UUID()
            let first = URL(fileURLWithPath: "/tmp/yuzu-first.png")
            let second = URL(fileURLWithPath: "/tmp/yuzu-second.png")
            session.begin(id: id, urls: [first, first])
            try expectEqual(session.urls, [first], "drag URLs are normalized")
            session.present()
            session.bind(sequenceNumber: 17)
            session.hover(0)
            session.updateURLs([first, first])
            try expectEqual(session.phase, .hoveringWedge(0), "unchanged normalized URLs preserve hover")
            session.updateURLs([second])
            try expectEqual(session.phase, .radialPresented, "new file selection invalidates hover")
            try expect(!session.commit(id: id, sequenceNumber: 17, index: 0), "previous selection cannot commit")
            session.hover(1)
            session.hover(nil)
            try expect(!session.commit(id: id, sequenceNumber: 17, index: 1), "mode-change hover invalidation prevents stale commit")
            session.hover(0)
            try expect(session.commit(id: id, sequenceNumber: 17, index: 0), "fresh hover can commit updated URLs")
            try expectEqual(session.urls, [second], "only current URLs reach commit")
        }

        runner.test("drag session never commits empty or non-file selections") {
            var session = RadialDragSession()
            let id = UUID()
            guard let remoteURL = URL(string: "https://example.invalid/image.png") else {
                throw TestFailure(description: "invalid URL test fixture")
            }
            session.begin(id: id, urls: [remoteURL])
            session.present()
            session.bind(sequenceNumber: 17)
            session.hover(0)
            try expect(session.urls.isEmpty, "non-file URLs are rejected")
            try expect(!session.commit(id: id, sequenceNumber: 17, index: 0), "empty selection cannot commit")
            session.updateURLs([URL(fileURLWithPath: "/tmp/yuzu-session.png")])
            session.hover(0)
            session.updateURLs([])
            try expectEqual(session.phase, .radialPresented, "lost URLs clear hover")
            session.hover(0)
            try expect(!session.commit(id: id, sequenceNumber: 17, index: 0), "lost selection cannot commit")
        }

        runner.test("terminal drag sessions clear state reject resurrection and permit a new drag") {
            let file = URL(fileURLWithPath: "/tmp/yuzu-session.png")
            for terminal in [RadialDragSession.Phase.completed, .cancelled, .failed] {
                var session = RadialDragSession()
                let oldID = UUID()
                session.begin(id: oldID, urls: [file])
                session.present()
                session.bind(sequenceNumber: 17)
                session.hover(2)
                switch terminal {
                case .completed:
                    try expect(session.commit(id: oldID, sequenceNumber: 17, index: 2), "commit before completing")
                    session.complete()
                case .cancelled: session.cancel()
                case .failed: session.fail()
                default: throw TestFailure(description: "unexpected terminal fixture")
                }
                try expectEqual(session.phase, terminal)
                try expect(!session.isActive && session.urls.isEmpty, "terminal state releases active files")
                try expectEqual(session.sequenceNumber, nil, "terminal state releases native sequence")
                try expect(!session.begin(id: oldID, urls: [file]), "late update cannot resurrect same drag")
                session.present()
                session.hover(1)
                session.updateURLs([file])
                session.complete()
                session.cancel()
                session.fail()
                try expectEqual(session.phase, terminal, "late callbacks preserve terminal state")
                try expect(!session.bind(sequenceNumber: 17), "terminal state cannot rebind")
                let newID = UUID()
                let nextFile = URL(fileURLWithPath: "/tmp/yuzu-next.pdf")
                try expect(session.begin(id: newID, urls: [nextFile]), "next drag starts independently")
                try expectEqual(session.phase, .dragging)
                try expectEqual(session.id, newID)
                try expectEqual(session.urls, [nextFile])
                try expectEqual(session.sequenceNumber, nil, "next drag has no stale sequence")
                try expect(!session.commit(id: oldID, sequenceNumber: 17, index: 2), "old drag cannot commit in new session")
            }
        }

        runner.test("drag failure during commit cannot dispatch again") {
            var session = RadialDragSession()
            let id = UUID()
            session.begin(id: id, urls: [URL(fileURLWithPath: "/tmp/yuzu-session.png")])
            session.present()
            session.bind(sequenceNumber: 17)
            session.hover(0)
            try expect(session.commit(id: id, sequenceNumber: 17, index: 0), "begin commit")
            session.fail()
            try expectEqual(session.phase, .failed)
            try expect(session.urls.isEmpty, "failed dispatch releases URLs")
            try expectEqual(session.sequenceNumber, nil)
            try expect(!session.commit(id: id, sequenceNumber: 17, index: 0), "failure cannot retry through late drop callback")
        }

        runner.test("radial active colors preserve the approved citrus palette") {
            let expected: [(NSColor, Int, Int, Int)] = [
                (Theme.citrusYellowNS, 248, 197, 55),
                (Theme.goldenAmberNS, 255, 159, 28),
                (Theme.deepAccentNS, 217, 119, 6),
                (Theme.softHighlightNS, 255, 244, 194),
                (Theme.activeTextNS, 37, 32, 20),
            ]
            for (color, red, green, blue) in expected {
                guard let rgb = color.usingColorSpace(.sRGB) else {
                    throw TestFailure(description: "palette color must support sRGB")
                }
                try expect(abs(rgb.redComponent * 255 - CGFloat(red)) < 0.01, "approved red channel")
                try expect(abs(rgb.greenComponent * 255 - CGFloat(green)) < 0.01, "approved green channel")
                try expect(abs(rgb.blueComponent * 255 - CGFloat(blue)) < 0.01, "approved blue channel")
                try expectEqual(rgb.alphaComponent, 1, "active colors remain opaque")
            }
        }

        runner.test("compression presets") {
            try expect(CompressionPreset.strong.imageQuality < CompressionPreset.balanced.imageQuality, "strong is smaller")
            try expect(CompressionPreset.strong.videoBitrateFactor < CompressionPreset.balanced.videoBitrateFactor, "strong video")
            try expectEqual(Compressor.outputFormat(for: URL(fileURLWithPath: "/tmp/a.svg")), .jpg)
            try expectEqual(Compressor.outputFormat(for: URL(fileURLWithPath: "/tmp/a.jpg")), .jpg)
            try expectEqual(Compressor.outputFormat(for: URL(fileURLWithPath: "/tmp/a.wav")), .m4a)
        }

        runner.test("FFmpeg timecode formatting") {
            try expectEqual(FFmpeg.timecode(3661.5), "01:01:01.500")
            try expectEqual(FFmpeg.timecode(0), "00:00:00.000")
        }

        runner.test("sf symbols resolve") {
            for tool in ToolID.allCases {
                try expect(NSImage(systemSymbolName: tool.symbol, accessibilityDescription: nil) != nil, "\(tool.rawValue) symbol \(tool.symbol)")
            }
            for category in FormatCategory.allCases {
                try expect(NSImage(systemSymbolName: category.symbol, accessibilityDescription: nil) != nil, "\(category.rawValue) symbol")
            }
        }

        await runner.testAsync("PDF exports complete PPTX XLSX EPUB and Markdown packages without changing its source") {
            try await withDocumentFixture { directory in
                let first = directory.appendingPathComponent("first.pdf")
                let second = directory.appendingPathComponent("second.pdf")
                try TextRenderer.writePDF("Page one\n=1+1\nYuzu & citrus", to: first)
                try TextRenderer.writePDF("Page two\nSecond sheet", to: second)
                guard let document = PDFDocument(url: first), let extra = PDFDocument(url: second)?.page(at: 0) else {
                    throw TestFailure(description: "cannot create PDF fixture")
                }
                document.insert(extra, at: 1)
                let source = directory.appendingPathComponent("two pages.pdf")
                try expect(document.write(to: source), "write two-page fixture")
                let original = try Data(contentsOf: source)
                let pptx = try await convertFixture(source, to: .pptx, in: directory)
                let slides = try await Shell.run("/usr/bin/unzip", ["-p", pptx.path, "ppt/presentation.xml"], outputLimit: 64 * 1_024)
                try expectEqual(try DocumentXML.parse(slides.stdout).elements.filter { $0.name == "sldId" }.count, 2)
                let xlsx = try await convertFixture(source, to: .xlsx, in: directory)
                let sheet = try await Shell.run("/usr/bin/unzip", ["-p", xlsx.path, "xl/worksheets/sheet1.xml"], outputLimit: 64 * 1_024)
                try expect(sheet.stdout.contains("=1+1"), "PDF text preserved")
                try expect(!sheet.stdout.contains("<f>"), "PDF content never becomes a formula")
                let workbook = try await Shell.run("/usr/bin/unzip", ["-p", xlsx.path, "xl/workbook.xml"], outputLimit: 64 * 1_024)
                try expectEqual(try DocumentXML.parse(workbook.stdout).elements.filter { $0.name == "sheet" }.count, 2)
                let epub = try await convertFixture(source, to: .epub, in: directory)
                let bookText = try await EPUBDocument.read(epub)
                try expect(bookText.contains("Page one") && bookText.contains("Page two"), "EPUB includes every page")
                let markdown = try await convertFixture(source, to: .md, in: directory)
                try expect(try String(contentsOf: markdown, encoding: .utf8).contains("Page two"), "Markdown includes every page")
                let images = try await convertFixture(source, to: .png, in: directory)
                try expectEqual(
                    try FileManager.default.contentsOfDirectory(at: images, includingPropertiesForKeys: nil).count, 2,
                    "all PDF page images are returned as a folder")
                try expectEqual(try Data(contentsOf: source), original, "source bytes preserved")
            }
        }

        await runner.testAsync("native spreadsheet and ebook conversions preserve literal data") {
            try await withDocumentFixture { directory in
                let csv = directory.appendingPathComponent("sample.csv")
                let rows = [["Name", "Code"], ["Yuzu, 🍋", "0012"], ["=1+1", "line\nwrap"]]
                try DelimitedText.serialize(rows, separator: ",").write(to: csv, atomically: true, encoding: .utf8)
                for target in [FileFormat.xlsx, .ods, .pdf, .tsv] {
                    let output = try await convertFixture(csv, to: target, in: directory)
                    try expect(FileManager.default.fileExists(atPath: output.path), "native spreadsheet output exists")
                    if target == .tsv { try expectEqual(DelimitedText.parse(TextFile.read(output), separator: "\t"), rows) }
                }
                let text = directory.appendingPathComponent("text.txt")
                try "Hello <Yuzu> & 🍋\nSecond paragraph".write(to: text, atomically: true, encoding: .utf8)
                let epub = try await convertFixture(text, to: .epub, in: directory)
                let roundTrip = try await convertFixture(epub, to: .txt, in: directory)
                try expect(try TextFile.read(roundTrip).contains("Hello <Yuzu> & 🍋"), "EPUB text round trip")
                _ = try await convertFixture(epub, to: .docx, in: directory)
                let html = try await convertFixture(text, to: .html, in: directory)
                try expect(try TextFile.read(html).contains("&lt;Yuzu&gt; &amp;"), "HTML escapes source content")
            }
        }

        await runner.testAsync("failed cancelled and colliding document conversions preserve source and clean staging") {
            try await withDocumentFixture { directory in
                let source = directory.appendingPathComponent("source.txt")
                try "Original".write(to: source, atomically: true, encoding: .utf8)
                let destination = directory.appendingPathComponent("existing.epub")
                let sentinel = Data("Keep this existing output".utf8)
                try sentinel.write(to: destination)
                do {
                    try await Engines.convert(
                        ConversionRequest(source: source, sourceFormat: .txt, target: .epub, destination: destination, progress: { _ in }))
                    throw TestFailure(description: "existing output was overwritten")
                } catch is TestFailure { throw TestFailure(description: "conversion should reject a collision") } catch {}
                try expectEqual(try Data(contentsOf: destination), sentinel)
                let cancelled = Task { try await convertFixture(source, to: .epub, in: directory) }
                cancelled.cancel()
                do { _ = try await cancelled.value; throw TestFailure(description: "cancelled work succeeded") } catch is CancellationError {}
                let invalid = directory.appendingPathComponent("invalid.pptx")
                try Data("not an Office package".utf8).write(to: invalid)
                do {
                    _ = try await convertFixture(invalid, to: .pdf, in: directory); throw TestFailure(description: "invalid PPTX succeeded")
                } catch is YuzuError {}
                let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
                try expect(!files.contains { $0.hasPrefix(".yuzu-") }, "staged output removed")
                try expectEqual(try TextFile.read(source), "Original")
            }
        }

        await runner.testAsync("EPUB archive traversal and output pipe overflow are rejected") {
            try await withDocumentFixture { directory in
                let contents = directory.appendingPathComponent("contents")
                try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
                try "Fixture".write(to: directory.appendingPathComponent("outside.txt"), atomically: true, encoding: .utf8)
                let archive = directory.appendingPathComponent("unsafe.epub")
                let packed = try await Shell.run("/usr/bin/zip", ["-q", archive.path, "../outside.txt"], currentDirectory: contents)
                try expect(packed.succeeded, "create traversal fixture")
                do { _ = try await DocumentArchive.open(archive); throw TestFailure(description: "unsafe archive accepted") } catch is YuzuError {}
                let bounded = try await Shell.run("/usr/bin/printf", ["123456789"], outputLimit: 4)
                try expect(bounded.outputTruncated, "overflow reported")
                try expectEqual(bounded.stdout, "1234", "capture remains bounded")
            }
        }

        await runner.testAsync("subprocess cancellation and launch failure finish without waiting for child output") {
            let child = Task { try await Shell.run("/bin/sleep", ["30"]) }
            try? await Task.sleep(nanoseconds: 100_000_000)
            child.cancel()
            do { _ = try await child.value; throw TestFailure(description: "cancelled subprocess returned normally") } catch is CancellationError {}
            do {
                _ = try await Shell.run("/no-such-yuzu-test-executable", []); throw TestFailure(description: "missing executable succeeded")
            } catch is TestFailure { throw TestFailure(description: "launch failure must throw") } catch {}
        }

        await runner.testAsync("RTFD packages enter the radial and export readable text") {
            try await withDocumentFixture { directory in
                let source = directory.appendingPathComponent("document.rtfd")
                let text = NSAttributedString(string: "Yuzu rich document")
                let wrapper = try text.fileWrapper(
                    from: NSRange(location: 0, length: text.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
                try wrapper.write(to: source, options: .atomic, originalContentsURL: nil)
                let radial = RadialProvider.content(for: [source], mode: .conversion)
                try expect(radial.items.contains { $0.action == .convert(.pdf) }, "RTFD is a document package, not an ordinary folder")
                let output = try await convertFixture(source, to: .txt, in: directory)
                try expect(try TextFile.read(output).contains("Yuzu rich document"), "RTFD text preserved")
            }
        }

        if OfficeEngine.executable != nil {
            await runner.testAsync("LibreOffice reads native PPTX XLSX ODS and DOCX output and exports all slides") {
                try await withDocumentFixture { directory in
                    let source = directory.appendingPathComponent("office source.pdf")
                    try TextRenderer.writePDF("Office fixture", to: source)
                    let pptx = try await convertFixture(source, to: .pptx, in: directory)
                    let pdf = try await convertFixture(pptx, to: .pdf, in: directory)
                    try expectEqual(PDFDocument(url: pdf)?.pageCount, 1, "PPTX opens and exports in LibreOffice")
                    let images = try await convertFixture(pptx, to: .jpg, in: directory)
                    try expect(ImageIOBridge.pixelSize(images).width > 0, "presentation page renders")
                    let csv = directory.appendingPathComponent("table.csv")
                    let originalRows = [["Name", "Code"], ["Yuzu", "0012"], ["  spaces  ", "line\nwrap"], ["tab\there", "_x0041_"], ["=1+1", "&<🍋>"]]
                    try DelimitedText.serialize(originalRows, separator: ",").write(to: csv, atomically: true, encoding: .utf8)
                    for target in [FileFormat.xlsx, .ods] {
                        let sheet = try await convertFixture(csv, to: target, in: directory)
                        let exported = try await convertFixture(sheet, to: .tsv, in: directory)
                        let rows = try DelimitedText.parse(TextFile.read(exported), separator: "\t")
                        try expectEqual(rows, originalRows, "spreadsheet strings survive LibreOffice")
                    }
                    let text = directory.appendingPathComponent("document.txt")
                    try "Yuzu document".write(to: text, atomically: true, encoding: .utf8)
                    let docx = try await convertFixture(text, to: .docx, in: directory)
                    let converted = try await convertFixture(docx, to: .pdf, in: directory)
                    try expect(PDFDocument(url: converted)?.string?.contains("Yuzu document") == true, "DOCX -> PDF is functional")
                    for target in [FileFormat.epub, .md, .html] {
                        _ = try await convertFixture(docx, to: target, in: directory)
                    }
                    guard let executable = OfficeEngine.executable else { throw TestFailure(description: "LibreOffice disappeared") }
                    let profile = directory.appendingPathComponent("legacy-profile")
                    try OfficeEngine.prepareProfile(profile)
                    let inputs = [
                        (pptx, "ppt:MS PowerPoint 97", FileFormat.pdf), (directory.appendingPathComponent("table.xlsx"), "xls:MS Excel 97", FileFormat.csv),
                    ]
                    for (input, filter, target) in inputs {
                        let result = try await Shell.run(
                            executable,
                            [
                                "-env:UserInstallation=\(profile.absoluteString)", "--headless", "--norestore", "--convert-to", filter, "--outdir",
                                directory.path, input.path,
                            ], outputLimit: 64 * 1_024)
                        try expect(result.succeeded, "create legacy Office fixture")
                        let legacy = input.deletingPathExtension().appendingPathExtension(filter.hasPrefix("ppt:") ? "ppt" : "xls")
                        _ = try await convertFixture(legacy, to: target, in: directory)
                    }
                    let richText = NSAttributedString(string: "RTF fixture")
                    let rtf = directory.appendingPathComponent("rich.rtf")
                    try richText.data(
                        from: NSRange(location: 0, length: richText.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
                    ).write(to: rtf)
                    let extracted = try await convertFixture(rtf, to: .txt, in: directory)
                    try expect(try TextFile.read(extracted).contains("RTF fixture"), "RTF input converts")
                }
            }
        } else {
            print("  skip LibreOffice integration: LibreOffice is not installed")
        }

        runner.finish()
    }
}
