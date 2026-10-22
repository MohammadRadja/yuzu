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

        await runner.testAsync("RTFD packages export readable text") {
            try await withDocumentFixture { directory in
                let source = directory.appendingPathComponent("document.rtfd")
                let text = NSAttributedString(string: "Yuzu rich document")
                let wrapper = try text.fileWrapper(
                    from: NSRange(location: 0, length: text.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
                try wrapper.write(to: source, options: .atomic, originalContentsURL: nil)
                try expectEqual(FileFormat.detect(source), .rtfd)
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
