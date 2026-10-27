import AppKit
import Foundation
import ImageIO
import PDFKit
import SwiftUI

struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

final class TestRunner {
    private var failures: [String] = []
    private var count = 0

    func test(_ name: String, _ body: () throws -> Void) {
        if ValidationRuntime.ownedGUI, let filter = ProcessInfo.processInfo.environment["YUZU_GUI_CASE"], !name.localizedCaseInsensitiveContains(filter) {
            return
        }
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
        if ValidationRuntime.ownedGUI, let filter = ProcessInfo.processInfo.environment["YUZU_GUI_CASE"], !name.localizedCaseInsensitiveContains(filter) {
            return
        }
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

@MainActor
final class RecordingJobHUD: JobHUD {
    private(set) var visible = false
    func show() { visible = true }
    func hide() { visible = false }
}

@MainActor
func waitForJobState(_ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(3)
    while !condition() {
        guard Date() < deadline else { throw TestFailure(description: "Timed out waiting for the job lifecycle") }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
}

func convertFixture(_ source: URL, to target: FileFormat, in directory: URL) async throws -> URL {
    guard let format = FileFormat.detect(source) else { throw TestFailure(description: "Unknown fixture format") }
    return try await Engines.convert(
        ConversionRequest(
            source: source, sourceFormat: format, target: target, destination: ConversionMatrix.outputURL(for: source, target: target, in: directory),
            progress: { _ in }))
}

func tarFixture(path: String, data: Data = Data("fixture".utf8), type: UInt8 = 48, link: String = "") -> Data {
    var header = [UInt8](repeating: 0, count: 512)
    func put(_ text: String, at offset: Int, length: Int) {
        for (index, byte) in text.utf8.prefix(length).enumerated() { header[offset + index] = byte }
    }
    put(path, at: 0, length: 100)
    put("0000600\0", at: 100, length: 8)
    put("0000000\0", at: 108, length: 8)
    put("0000000\0", at: 116, length: 8)
    put(String(repeating: "0", count: max(0, 11 - String(data.count, radix: 8).count)) + String(data.count, radix: 8) + "\0", at: 124, length: 12)
    put("00000000000\0", at: 136, length: 12)
    put("        ", at: 148, length: 8)
    header[156] = type
    put(link, at: 157, length: 100)
    put("ustar\0", at: 257, length: 6)
    put("00", at: 263, length: 2)
    let checksum = header.reduce(0) { $0 + Int($1) }
    put(String(format: "%06o", checksum) + "\0 ", at: 148, length: 8)
    var result = Data(header)
    result.append(data)
    result.append(Data(repeating: 0, count: (512 - data.count % 512) % 512 + 1024))
    return result
}

#if !YUZU_OWNED_GUI_BINARY
    @main
#endif
@MainActor
struct YuzuTests {
    static func main() async {
        let runner = TestRunner()

        if CommandLine.arguments.dropFirst().first == "--qa-shelf-reopen" {
            RoadmapValidation.reopenedShelf(runner)
            runner.finish()
        }
        if ProcessInfo.processInfo.environment["YUZU_VOLUME_TESTS"] == "1" {
            await RoadmapValidation.volumeLifecycle(runner)
            runner.finish()
        }

        if ValidationRuntime.ownedGUI {
            fputs("Use scripts/check-gui.sh to run the AppKit event-loop GUI test host\n", stderr)
            exit(2)
        }

        if ValidationRuntime.nativeOnly {
            guard ValidationRuntime.isolatedDefaults != nil else {
                fputs("Native validation requires an isolated YuzuQA defaults suite\n", stderr)
                exit(2)
            }
            await RoadmapValidation.nativeOnly(runner)
            runner.finish()
        }
        await RoadmapValidation.register(runner)

        runner.test("archive panel completes only after every tracked job succeeds and supports retry") {
            let submission = ArchiveSubmission()
            let first = Job(title: "Extract", detail: "one"), second = Job(title: "Extract", detail: "two")
            submission.track([first, second])
            first.status = .running
            first.progress = 1
            try expectEqual(submission.status, .running, "100% progress alone is not completion")
            first.status = .done
            try expectEqual(submission.status, .running, "wait for every selected archive")
            second.status = .failed("fixture failure")
            try expectEqual(submission.status, .failed("fixture failure"), "partial failure keeps panel open")
            let retry = Job(title: "Create ZIP", detail: "retry")
            submission.track([retry])
            second.status = .done
            try expectEqual(submission.status, .running, "old submissions cannot close a retry")
            retry.status = .cancelled
            try expectEqual(submission.status, .cancelled, "cancellation permits retry without success dismissal")
            let success = Job(title: "Create ZIP", detail: "success")
            submission.track([success])
            success.status = .done
            try expectEqual(submission.status, .succeeded)
        }

        await runner.testAsync("real ZIP job completes its panel submission and dismisses its HUD without native windows") {
            try await withDocumentFixture { directory in
                let source = directory.appendingPathComponent("original.txt"), output = directory.appendingPathComponent("selection.zip")
                try Data("ZIP lifecycle fixture".utf8).write(to: source)
                let hud = RecordingJobHUD()
                let jobs = JobRunner(completionDelay: 0.02, automaticallyRevealsOutputs: false, makeHUD: { _, _ in hud })
                defer { jobs.cancelAll() }
                let submission = ArchiveSubmission()
                let zip = jobs.run(title: "Creating ZIP", detail: "fixture") { progress in
                    try await FileOperations.createZIP([source], to: output, progress: progress)
                    return [output]
                }
                submission.track([zip])
                try await waitForJobState { submission.status == .succeeded }
                try expectEqual(zip.outputs, [output], "commit precedes success")
                try await OutputValidator.validate(output, as: .zip)
                try await waitForJobState { jobs.jobs.isEmpty }
                try expect(!hud.visible, "successful ZIP HUD dismissed")
                try expectEqual(try String(contentsOf: source, encoding: .utf8), "ZIP lifecycle fixture")
            }
        }

        await runner.testAsync("retained failure cannot pin a later successful job in the progress HUD") {
            let hud = RecordingJobHUD()
            let jobs = JobRunner(completionDelay: 0.02, automaticallyRevealsOutputs: false, makeHUD: { _, _ in hud })
            defer { jobs.cancelAll() }
            let failure = jobs.run(title: "Failing", detail: "fixture") { _ in throw YuzuError.encodeFailed("fixture") }
            let success = jobs.run(title: "Creating ZIP", detail: "success fixture") { _ in [] }
            try await waitForJobState { failure.status.isFinished && success.status == .done }
            try await waitForJobState { !jobs.jobs.contains { $0.id == success.id } }
            try expectEqual(jobs.jobs.map(\.id), [failure.id], "only the readable failure remains")
            try expect(hud.visible, "failure remains available for dismissal")
            jobs.dismiss(failure)
            try expect(jobs.jobs.isEmpty && !hud.visible, "dismissing the failure closes the HUD")
        }

        await runner.testAsync("completed job cleanup preserves another running job and ignores late progress") {
            let hud = RecordingJobHUD()
            let jobs = JobRunner(completionDelay: 0.02, automaticallyRevealsOutputs: false, makeHUD: { _, _ in hud })
            defer { jobs.cancelAll() }
            let success = jobs.run(title: "Complete", detail: "fixture") { progress in
                progress(0.3); return []
            }
            try await waitForJobState { success.status == .done }
            let active = jobs.run(title: "Running", detail: "fixture") { _ in
                try await Task.sleep(nanoseconds: 10_000_000_000)
                return []
            }
            try await waitForJobState { active.status == .running && !jobs.jobs.contains { $0.id == success.id } }
            try expectEqual(success.progress, 1, "late callbacks cannot regress finished progress")
            try expectEqual(jobs.jobs.map(\.id), [active.id])
            try expect(hud.visible, "cleanup must not hide active progress")
            jobs.cancel(active)
            await active.task?.value
            try expect(jobs.jobs.isEmpty && !hud.visible, "cancelling the last job closes the HUD")
        }

        runner.test("Make a Copy and Duplicate Finder have distinct labels operations and mode ownership") {
            let file = URL(fileURLWithPath: "/tmp/yuzu-copy-label.txt")
            func flattened(_ items: [RadialItem]) -> [RadialItem] {
                items.flatMap { item in
                    if case .more(let nested) = item.action { return flattened(nested) }; return [item]
                }
            }
            let actions = flattened(RadialProvider.content(for: [file], mode: .actions).items)
            let tasks = flattened(RadialProvider.content(for: [file], mode: .flow).items)
            let copy = actions.first { $0.action == .file(.duplicate) }
            let finder = tasks.first { $0.action == .task(.duplicateFinder) }
            try expectEqual(copy?.label, "Make a Copy")
            try expectEqual(finder?.label, "Duplicate Finder")
            try expect(copy?.detail.contains("copies") == true && finder?.detail.contains("identical") == true, "labels explain distinct behavior")
            try expect(!actions.contains { $0.action == .task(.duplicateFinder) }, "finder stays in Tasks")
            try expect(!tasks.contains { $0.action == .file(.duplicate) }, "copy stays in Actions")
        }

        runner.test("P3 XML mapping recognition never drops ordinary JSON sibling or node properties") {
            let node: [String: Any] = ["name": "root", "attributes": [String: String](), "children": [Any]()]
            let ordinary: [String: Any] = ["$xml": node, "keep": "original data"]
            let decoded = try XMLJSON.read(XMLJSON.write(ordinary)) as? NSDictionary
            try expectEqual(decoded, ordinary as NSDictionary)
            var extendedNode = node
            extendedNode["keep"] = "node data"
            let extended: [String: Any] = ["$xml": extendedNode]
            try expectEqual(try XMLJSON.read(XMLJSON.write(extended)) as? NSDictionary, extended as NSDictionary)
            let nested: [String: Any] = ["$xml": ["name": "root", "attributes": [String: String](), "children": [extendedNode]]]
            try expectEqual(try XMLJSON.read(XMLJSON.write(nested)) as? NSDictionary, nested as NSDictionary)
            try expect(try XMLJSON.write(XMLJSON.read("<root>kept</root>")).contains("<root>kept</root>"), "real XML mapping still reconstructs")
        }

        runner.test("P0 channel conversion and visualizer require their actual FFmpeg filters and decoders") {
            var capabilities = BackendCapabilities(ffmpegPath: "/fixture/ffmpeg")
            try expect(!capabilities.supports(tool: .audioChannels, formats: [.wav]), "native gain cannot implement channel routing")
            capabilities.encoders = ["pcm_s16le", "libx264", "aac"]
            capabilities.muxers = ["wav", "mp4"]
            capabilities.filters = ["pan", "showwaves", "showfreqs", "color", "scale"]
            try expect(!capabilities.supports(tool: .audioChannels, formats: [.wav]), "missing audio decoder")
            try expect(!capabilities.supports(tool: .audioToVideo, formats: [.wav]), "visualizer needs input decoder")
            capabilities.decoders = ["pcm_s16le"]
            try expect(capabilities.supports(tool: .audioChannels, formats: [.wav]), "complete channel backend")
            try expect(capabilities.supports(tool: .audioToVideo, formats: [.wav]), "complete visualizer backend")
            capabilities.filters.remove("pan")
            try expect(!capabilities.supports(tool: .audioChannels, formats: [.wav]), "encoder presence does not provide pan")
        }

        runner.test("P3 structured conversion preserves XML whitespace and refuses unrepresentable control characters") {
            let input: [String: Any] = ["key\nwith\ttabs": "line\rbreak"]
            let result = try XMLJSON.read(XMLJSON.write(input)) as? [String: String]
            try expectEqual(result?["key\nwith\ttabs"], "line\rbreak")
            do { _ = try XMLJSON.write(["value": "\u{0}"]); throw TestFailure(description: "control character silently dropped") } catch is YuzuError {}
            let unicode = "<数据 名称=\"柚子\">内容</数据>"
            try expect(try XMLJSON.write(XMLJSON.read(unicode)).contains("<数据"), "Unicode element names retained")
        }

        await runner.testAsync("P0 staging stays private and committed output preserves restrictive source permissions") {
            try await withDocumentFixture { directory in
                let source = directory.appendingPathComponent("private.txt"), output = directory.appendingPathComponent("copy.txt")
                try Data("secret".utf8).write(to: source)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: source.path)
                try await OutputTransaction.write(source: source, destination: output, format: .txt) { staged in
                    let mode = try FileManager.default.attributesOfItem(atPath: staged.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber
                    try expectEqual((mode?.intValue ?? 0) & 0o777, 0o700, "private staging container")
                    try Data("copy".utf8).write(to: staged)
                }
                let mode = try FileManager.default.attributesOfItem(atPath: output.path)[.posixPermissions] as? NSNumber
                try expectEqual((mode?.intValue ?? 0) & 0o777, 0o600)
                let yaml = try YAMLDocument.read("message: it's Yuzu\nflag: True\n") as? [String: Any]
                try expectEqual(yaml?["message"] as? String, "it's Yuzu")
                try expectEqual(yaml?["flag"] as? Bool, true)
                do {
                    _ = try YAMLDocument.read("number: 0012"); throw TestFailure(description: "ambiguous numeric scalar changed type silently")
                } catch is YuzuError {}
            }
        }

        await runner.testAsync("P4 archive manager selects entries and unlocks encrypted ZIP with correct password only") {
            try await withDocumentFixture { directory in
                let first = directory.appendingPathComponent("first.txt"), second = directory.appendingPathComponent("second.txt")
                try Data("first".utf8).write(to: first); try Data("second".utf8).write(to: second)
                let archive = directory.appendingPathComponent("encrypted.zip")
                let packed = try await Shell.run(
                    "/usr/bin/zip", ["-q", "-P", "fixture-password", archive.path, "first.txt", "second.txt"], currentDirectory: directory)
                try expect(packed.succeeded, "ZIP fixture")
                let entries = try await FileOperations.inspectArchive(archive, password: "fixture-password")
                try expectEqual(entries.count, 2)
                let output = directory.appendingPathComponent("selected")
                try await FileOperations.extract(archive, to: output, selected: ["second.txt"], password: "fixture-password", progress: { _ in })
                try expectEqual(try FileManager.default.contentsOfDirectory(atPath: output.path), ["second.txt"])
                do {
                    try await FileOperations.extract(archive, to: directory.appendingPathComponent("wrong"), password: "wrong", progress: { _ in })
                    throw TestFailure(description: "incorrect archive password accepted")
                } catch is YuzuError {}
                if EncryptedZIP.isSupported {
                    let aes = directory.appendingPathComponent("AES.zip")
                    try await EncryptedZIP.create([first, second], to: aes, password: "AES-fixture", progress: { _ in })
                    let decrypted = directory.appendingPathComponent("decrypted")
                    try await FileOperations.extract(aes, to: decrypted, password: "AES-fixture", progress: { _ in })
                    try expectEqual(try TextFile.read(decrypted.appendingPathComponent("first.txt")), "first")
                    let repacked = directory.appendingPathComponent("repacked.zip")
                    try await ArchiveRepack.export(
                        aes, selected: ["second.txt"], currentPassword: "AES-fixture", newPassword: nil, to: repacked, progress: { _ in })
                    try expectEqual(try SafeArchive.inspect(repacked).map(\.path), ["second.txt"], "repack selected entries as unprotected copy")
                } else {
                    print("  SKIP AES ZIP creation: system libarchive lacks encryption support")
                }
            }
        }

        await runner.testAsync("P3 bundled animation encodes native video without an FFmpeg encoder") {
            try await withDocumentFixture { directory in
                let source = directory.appendingPathComponent("video.mp4")
                try await SampleMedia.writeVideo(to: source, seconds: 0.5, hue: 0.2)
                let original = try FileHash.sha256(source)
                let output = try await convertFixture(source, to: .webp, in: directory)
                try expect(try NativeWebPAnimation.validate(output), "generated video animation decodes")
                try expect(try Data(contentsOf: output).range(of: Data("ANIM".utf8)) != nil, "multiple frames retained")
                try expectEqual(try FileHash.sha256(source), original)
            }
        }

        await runner.testAsync("P3 Vision background removal renders a real repository image without altering it") {
            try await withDocumentFixture { directory in
                let source = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(
                    "Assets.xcassets/AppIcon.appiconset/icon_512x512@1x.png")
                let original = try FileHash.sha256(source)
                let output = directory.appendingPathComponent("foreground.png")
                try await AdvancedImageOps.removeBackground(source, to: output)
                try await OutputValidator.validate(output, as: .png)
                try expectEqual(ImageIOBridge.pixelSize(output), CGSize(width: 512, height: 512))
                try expectEqual(try FileHash.sha256(source), original)
            }
        }

        await runner.testAsync("P4 new folder with selection moves safely and refuses an existing folder") {
            try await withDocumentFixture { directory in
                let first = directory.appendingPathComponent("first.txt"), second = directory.appendingPathComponent("second.txt")
                try Data("first".utf8).write(to: first); try Data("second".utf8).write(to: second)
                let folder = try await FileOperations.newFolder([first, second], name: "Grouped")
                try expectEqual(try TextFile.read(folder.appendingPathComponent("first.txt")), "first")
                do {
                    _ = try await FileOperations.newFolder([folder.appendingPathComponent("first.txt")], name: "..")
                    throw TestFailure(description: "invalid folder name accepted")
                } catch is YuzuError {}
                let extra = directory.appendingPathComponent("extra.txt")
                try Data("extra".utf8).write(to: extra)
                do {
                    _ = try await FileOperations.newFolder([extra], name: "Grouped"); throw TestFailure(description: "existing folder reused")
                } catch is YuzuError {}
                try expectEqual(try TextFile.read(extra), "extra")
            }
        }

        runner.test("P4 mode ownership has no duplicate sharing or legacy task aliases") {
            func flatten(_ items: [RadialItem]) -> [RadialAction] {
                items.flatMap { item in
                    if case .more(let children) = item.action { return flatten(children) }; return [item.action]
                }
            }
            let files = [URL(fileURLWithPath: "/tmp/a.png"), URL(fileURLWithPath: "/tmp/b.png")]
            let actions = flatten(RadialProvider.content(for: files, mode: .actions).items)
            try expectEqual(actions.filter { $0 == .file(.share) }.count, 1)
            try expect(!actions.contains(.file(.airDrop)), "AirDrop is available inside the single system Share picker")
            let tasks = flatten(RadialProvider.content(for: files, mode: .flow).items)
            try expect(tasks.contains(.task(.batchRename)) && tasks.contains(.task(.fileShelf)), "dedicated Tasks")
            try expect(!tasks.contains(.file(.rename)) && !tasks.contains(.file(.move)) && !tasks.contains(.tool(.compress)), "aliases removed after migration")
            let tools = flatten(RadialProvider.content(for: files, mode: .tools).items)
            try expect(!tools.contains(.file(.quickLook)) && !tools.contains(.file(.createZIP)), "Actions ownership")
        }

        await runner.testAsync("P3 icons and multi-image GIF are valid native image containers") {
            try await withDocumentFixture { directory in
                let a = directory.appendingPathComponent("a.png"), b = directory.appendingPathComponent("b.png")
                try ImageIOBridge.write(SampleMedia.image(width: 100, height: 80, hue: 0.2), to: a, format: .png)
                try ImageIOBridge.write(SampleMedia.image(width: 80, height: 100, hue: 0.6), to: b, format: .png)
                for format: FileFormat in [.ico, .icns] {
                    let output = try await convertFixture(a, to: format, in: directory)
                    try await OutputValidator.validate(output, as: format)
                }
                let gif = directory.appendingPathComponent("animation.gif")
                try await AnimatedGIFWriter.write([a, b], to: gif, progress: { _ in })
                let source = CGImageSourceCreateWithURL(gif as CFURL, nil)
                try expectEqual(source.map(CGImageSourceGetCount), 2, "two actual GIF frames")
                let capabilities = await RuntimeCapabilities.refresh()
                if NativeWebPAnimation.isAvailable || capabilities.canEncodeMedia(.webp) && capabilities.canDecodeMedia(.gif) {
                    let output = try await convertFixture(gif, to: .webp, in: directory)
                    let bytes = try Data(contentsOf: output)
                    try expect(bytes.range(of: Data("ANIM".utf8)) != nil && bytes.range(of: Data("ANMF".utf8)) != nil, "animation retained in WebP")
                } else {
                    print("  SKIP animated WebP: FFmpeg libwebp_anim unavailable")
                }
            }
        }

        await runner.testAsync("P3 HTML text clipping and PDF SVG export real parseable documents") {
            try await withDocumentFixture { directory in
                let html = directory.appendingPathComponent("source.html")
                try
                    "<!doctype html><html><head><script>NEVER EXECUTE</script></head><body><p>Yuzu <b>offline HTML</b></p><img src=\"https://invalid.example/image.png\"></body></html>"
                    .write(to: html, atomically: false, encoding: .utf8)
                for target: FileFormat in [.txt, .pdf, .docx] {
                    let output = try await convertFixture(html, to: target, in: directory)
                    try await OutputValidator.validate(output, as: target)
                    if target == .txt { try expectEqual(try TextFile.read(output), "Yuzu offline HTML") }
                }
                let clipping = directory.appendingPathComponent("source.textClipping")
                try PropertyListSerialization.data(
                    fromPropertyList: ["UTI-Data": ["public.utf8-plain-text": Data("Yuzu clipping".utf8)]], format: .binary, options: 0
                ).write(to: clipping)
                for target: FileFormat in [.txt, .md, .pdf] { _ = try await convertFixture(clipping, to: target, in: directory) }
                let pdf = directory.appendingPathComponent("document.pdf")
                try TextRenderer.writePDF("Yuzu SVG", to: pdf)
                let svg = try await convertFixture(pdf, to: .svg, in: directory)
                try await OutputValidator.validate(svg, as: .svg)
                try expect(try TextFile.read(svg).contains("data:image/png;base64,"), "SVG embeds page appearance")
            }
        }

        await runner.testAsync("P3 JSON YAML and XML round trips retain scalar types and reject unsafe YAML/XML") {
            try await withDocumentFixture { directory in
                let source = directory.appendingPathComponent("data.json")
                let original = "{\"name\":\"Yuzu & <🍋>\",\"enabled\":true,\"nothing\":null,\"items\":[1,\"0012\",false]}"
                try original.write(to: source, atomically: false, encoding: .utf8)
                let expected = try JSONSerialization.jsonObject(with: Data(original.utf8)) as? NSDictionary
                for format: FileFormat in [.yaml, .xml] {
                    let converted = try await convertFixture(source, to: format, in: directory)
                    let back = try await convertFixture(converted, to: .json, in: directory)
                    let actual = try JSONSerialization.jsonObject(with: Data(contentsOf: back)) as? NSDictionary
                    try expectEqual(actual, expected, "\(format) round trip")
                }
                let yaml = try YAMLDocument.read("name: Yuzu\nitems:\n  - first\n  - key: value\n    flag: true\n") as? [String: Any]
                try expectEqual(yaml?["name"] as? String, "Yuzu")
                for invalid in ["x: &anchor value", "x: |\n  text", "a: one\na: two", "---\na: one\n---\nb: two"] {
                    do { _ = try YAMLDocument.read(invalid); throw TestFailure(description: "unsupported YAML silently accepted") } catch is YuzuError {}
                }
                do {
                    _ = try XMLJSON.read("<!DOCTYPE a [<!ENTITY x SYSTEM 'file:///etc/passwd'>]><a>&x;</a>");
                    throw TestFailure(description: "external XML entity accepted")
                } catch is YuzuError {}
                let xml = "<root answer=\"42\">before<item>value</item>after</root>"
                let roundTrip = try XMLJSON.write(XMLJSON.read(xml))
                try expect(roundTrip.contains("before<item>value</item>after"), "mixed XML content order preserved")
            }
        }

        await runner.testAsync("P3 workflow runs actual sequential operations and rejects incompatible steps") {
            try await withDocumentFixture { directory in
                let source = directory.appendingPathComponent("source.png")
                try ImageIOBridge.write(SampleMedia.image(width: 160, height: 100, hue: 0.4), to: source, format: .png)
                let original = try Data(contentsOf: source)
                let steps = [WorkflowStep(kind: .resize, longEdge: 80), WorkflowStep(kind: .convert, target: "jpg")]
                let output = directory.appendingPathComponent("workflow.jpg")
                try await WorkflowEngine.run(source, steps: steps, to: output, progress: { _ in })
                try expectEqual(ImageIOBridge.pixelSize(output).width, 80)
                try expectEqual(try Data(contentsOf: source), original)
                do {
                    _ = try WorkflowEngine.validate([WorkflowStep(kind: .ocr), WorkflowStep(kind: .resize)], source: .png)
                    throw TestFailure(description: "incompatible workflow accepted")
                } catch is YuzuError {}
                try expect(!(try FileManager.default.contentsOfDirectory(atPath: directory.path)).contains { $0.hasPrefix(".yuzu-") }, "intermediates cleaned")
            }
        }

        await runner.testAsync("P3 streaming duplicate scan ignores links and comparison reports line differences") {
            try await withDocumentFixture { directory in
                let a = directory.appendingPathComponent("a.txt"), b = directory.appendingPathComponent("b.txt"), c = directory.appendingPathComponent("c.txt")
                try Data("one\ntwo\n".utf8).write(to: a); try FileManager.default.copyItem(at: a, to: b)
                try Data("one\nsix\n".utf8).write(to: c)
                try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("link"), withDestinationURL: a)
                let groups = try await DuplicateFinder.find([directory], progress: { _ in })
                try expectEqual(groups.count, 1)
                try expectEqual(Set(groups[0].urls), Set([a, b]))
                let comparison = try await FileComparison.compare(a, c)
                try expect(!comparison.identical && comparison.insertions == 1 && comparison.removals == 1, "line change detected")
                let upscaled = directory.appendingPathComponent("upscaled.png")
                let png = directory.appendingPathComponent("source.png")
                try ImageIOBridge.write(SampleMedia.image(width: 80, height: 60, hue: 0.1), to: png, format: .png)
                try await AdvancedImageOps.upscale(png, factor: 2, to: upscaled)
                try expectEqual(ImageIOBridge.pixelSize(upscaled), CGSize(width: 160, height: 120))
            }
        }

        await runner.testAsync("P3 shelf persists references marks missing files and visual PDF signing keeps source") {
            try await withDocumentFixture { directory in
                let suite = "yuzu-shelf-tests-\(UUID().uuidString)"
                guard let defaults = UserDefaults(suiteName: suite) else { throw TestFailure(description: "isolated shelf preferences") }
                defer { defaults.removePersistentDomain(forName: suite) }
                let source = directory.appendingPathComponent("source.txt")
                try Data("shelf".utf8).write(to: source)
                let shelf = FileShelfStore(defaults: defaults)
                try shelf.add([source, source]); try expectEqual(shelf.items.count, 1)
                let restored = FileShelfStore(defaults: defaults)
                var ref = restored.items[0]
                try expectEqual(ref.resolve()?.resolvingSymlinksInPath(), source.resolvingSymlinksInPath())
                try FileManager.default.removeItem(at: source)
                try expectEqual(ref.resolve(), nil, "missing reference is not silently reused")
                let pdf = directory.appendingPathComponent("source.pdf")
                try TextRenderer.writePDF("Visual signature fixture", to: pdf)
                let original = try Data(contentsOf: pdf)
                let signature = directory.appendingPathComponent("signature.png")
                try ImageIOBridge.write(SampleMedia.image(width: 100, height: 40, hue: 0.2), to: signature, format: .png)
                let output = directory.appendingPathComponent("signed.pdf")
                try await VisualPDFSignature.export(pdf, to: output, page: 1, options: WatermarkOptions(image: signature))
                try expectEqual(PDFDocument(url: output)?.pageCount, 1)
                try expectEqual(try Data(contentsOf: pdf), original)
            }
        }

        await runner.testAsync("P2 mid-batch cancellation restores staged names and keeps completed optimization copies") {
            try await withDocumentFixture { directory in
                let a = directory.appendingPathComponent("a.txt"), b = directory.appendingPathComponent("b.txt")
                try Data("A".utf8).write(to: a); try Data("B".utf8).write(to: b)
                var options = RenameOptions()
                options.prefix = "renamed-"
                let plan = try BatchOperations.renamePlan([a, b], options: options)
                let rename = Task {
                    try await BatchOperations.apply(plan) { _ in withUnsafeCurrentTask { $0?.cancel() } }
                }
                do { _ = try await rename.value; throw TestFailure(description: "staged cancellation ignored") } catch is CancellationError {}
                try expectEqual(try String(contentsOf: a), "A")
                try expectEqual(try String(contentsOf: b), "B")
                try expect(plan.allSatisfy { !FileManager.default.fileExists(atPath: $0.destination.path) }, "rename rollback restored all source names")

                let images = ["first.png", "second.png"].map { directory.appendingPathComponent($0) }
                for image in images { try ImageIOBridge.write(SampleMedia.image(width: 80, height: 60, hue: 0.2), to: image, format: .png) }
                let originals = try images.map { try Data(contentsOf: $0) }
                let optimize = Task {
                    try await BatchOptimizer.run(images, preset: .balanced, directory: .besideOriginal, progress: { _ in }) { _ in
                        withUnsafeCurrentTask { $0?.cancel() }
                    }
                }
                do { _ = try await optimize.value; throw TestFailure(description: "batch optimization cancellation ignored") } catch is CancellationError {}
                let contents = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                let outputs = contents.filter { $0.lastPathComponent.contains("optimized") }
                try expectEqual(outputs.count, 1, "completed output survives cancellation; next file is not processed")
                guard let output = outputs.first else { throw TestFailure(description: "completed output missing") }
                try await OutputValidator.validate(output, as: .png)
                try expectEqual(try images.map { try Data(contentsOf: $0) }, originals, "original images preserved")
                try expect(!contents.contains { $0.lastPathComponent.hasPrefix(".yuzu-") }, "partial staging cleaned")
            }
        }

        await runner.testAsync("P2 batch rename previews patterns detects conflicts and applies a two-phase swap") {
            try await withDocumentFixture { directory in
                let a = directory.appendingPathComponent("a.txt"), b = directory.appendingPathComponent("b.txt")
                try Data("A".utf8).write(to: a); try Data("B".utf8).write(to: b)
                var options = RenameOptions()
                options.prefix = "Yuzu-"; options.suffix = "-done"; options.pattern = "{name}-{n}"
                let plan = try BatchOperations.renamePlan([a, b], options: options)
                try expectEqual(plan.map { $0.destination.lastPathComponent }, ["Yuzu-a-001-done.txt", "Yuzu-b-002-done.txt"])
                try expectEqual(try String(contentsOf: a, encoding: .utf8), "A", "preview is read-only")
                let swap = [FileChange(source: a, destination: b), FileChange(source: b, destination: a)]
                _ = try await BatchOperations.apply(swap, progress: { _ in })
                try expectEqual(try String(contentsOf: a, encoding: .utf8), "B")
                try expectEqual(try String(contentsOf: b, encoding: .utf8), "A")
                options.pattern = "same"
                do {
                    _ = try BatchOperations.renamePlan([a, b], options: options); throw TestFailure(description: "duplicate names accepted")
                } catch is YuzuError {}
                options.pattern = "../bad"
                do {
                    _ = try BatchOperations.renamePlan([a, b], options: options); throw TestFailure(description: "invalid names accepted")
                } catch is YuzuError {}
            }
        }

        await runner.testAsync("P2 organize previews destinations and batch optimize returns per-file sizes and errors") {
            try await withDocumentFixture { directory in
                let a = directory.appendingPathComponent("a.png"), b = directory.appendingPathComponent("b.png")
                try ImageIOBridge.write(SampleMedia.image(width: 200, height: 100, hue: 0.2), to: a, format: .png)
                try Data("corrupt".utf8).write(to: b)
                let plan = try BatchOperations.organizePlan([a, b], byDate: false)
                try expectEqual(plan[0].destination.deletingLastPathComponent().lastPathComponent, "Image")
                let report = try await BatchOptimizer.run([a, b], preset: .strong, directory: .besideOriginal, progress: { _ in })
                try expectEqual(report.count, 2)
                try expect(report[0].output != nil && report[0].before > 0 && report[0].after > 0, "successful file size report")
                try expect(report[1].output == nil && report[1].error != nil, "individual failure reported")
                let organized = try await BatchOperations.apply(plan, progress: { _ in })
                try expect(organized.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }, "organize actually moved files")
            }
        }

        await runner.testAsync("P2 PDF password protects unlocks validates password and preserves original") {
            try await withDocumentFixture { directory in
                let source = directory.appendingPathComponent("source.pdf")
                try TextRenderer.writePDF("Yuzu password fixture", to: source)
                let original = try Data(contentsOf: source)
                let protected = directory.appendingPathComponent("protected.pdf")
                try await PDFPasswordOps.export(source, to: protected, currentPassword: "", newPassword: "fixture-password", authorized: true)
                let locked = PDFDocument(url: protected)
                try expect(locked?.isEncrypted == true && locked?.isLocked == true, "protected document starts locked")
                let unlocked = directory.appendingPathComponent("unlocked.pdf")
                do {
                    try await PDFPasswordOps.export(protected, to: unlocked, currentPassword: "wrong", newPassword: nil, authorized: true)
                    throw TestFailure(description: "incorrect password accepted")
                } catch is YuzuError {}
                try await PDFPasswordOps.export(protected, to: unlocked, currentPassword: "fixture-password", newPassword: nil, authorized: true)
                try expect(PDFDocument(url: unlocked)?.isEncrypted == false, "protection removed")
                try expect(PDFDocument(url: unlocked)?.string?.contains("Yuzu password fixture") == true, "text preserved")
                try expectEqual(try Data(contentsOf: source), original)
            }
        }

        await runner.testAsync("P2 watermark exports actual image and PDF content and Vision recognizes scanned PDF") {
            try await withDocumentFixture { directory in
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
                let text = try await OCROps.text(pdf, progress: { _ in })
                try expect(text.localizedCaseInsensitiveContains("Yuzu"), "Vision recognized actual rendered text: \(text)")
                let txt = directory.appendingPathComponent("OCR.txt")
                try await OCROps.export(pdf, to: txt, progress: { _ in })
                try expect(try String(contentsOf: txt, encoding: .utf8).localizedCaseInsensitiveContains("Yuzu"), "OCR exported valid text")
            }
        }

        await runner.testAsync("P1 ZIP round trip preserves folder structure originals and refuses overwrites") {
            try await withDocumentFixture { directory in
                let folder = directory.appendingPathComponent("folder")
                try FileManager.default.createDirectory(at: folder.appendingPathComponent("nested"), withIntermediateDirectories: true)
                let first = folder.appendingPathComponent("nested/é 🍋.txt")
                try Data("original".utf8).write(to: first)
                let second = directory.appendingPathComponent("second.txt")
                try Data("second".utf8).write(to: second)
                let archive = directory.appendingPathComponent("selection.zip")
                try await FileOperations.createZIP([folder, second], to: archive, progress: { _ in })
                try await OutputValidator.validate(archive, as: .zip)
                let entries = try SafeArchive.inspect(archive)
                try expect(entries.contains { $0.path == "folder/nested/é 🍋.txt" }, "nested member")
                let output = directory.appendingPathComponent("extracted")
                try await FileOperations.extract(archive, to: output, progress: { _ in })
                try expectEqual(try String(contentsOf: output.appendingPathComponent("folder/nested/é 🍋.txt")), "original")
                try expectEqual(try String(contentsOf: first), "original", "source unchanged")
                do {
                    try await FileOperations.extract(archive, to: output, progress: { _ in })
                    throw TestFailure(description: "existing destination overwritten")
                } catch is YuzuError {}
                let copy = directory.appendingPathComponent("folder copy")
                try await FileOperations.duplicate(folder, to: copy)
                try expectEqual(try String(contentsOf: copy.appendingPathComponent("nested/é 🍋.txt")), "original")
                try expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(".yuzu-extract").path), "no partial output")
            }
        }

        await runner.testAsync("P1 real RAR subblock and RAR5 archives extract exact contents without changing sources") {
            try await withDocumentFixture { directory in
                let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/Archives")
                let cases = [
                    ("test_read_format_rar_subblock.rar", "test.txt", "test text document\r\n"),
                    ("test_read_format_rar5_stored.rar", "helloworld.txt", "hello libarchive test suite!\n"),
                ]
                for (name, member, expected) in cases {
                    let source = fixtures.appendingPathComponent(name)
                    let original = try Data(contentsOf: source)
                    try expectEqual(try SafeArchive.inspect(source).map(\.path), [member])
                    let output = directory.appendingPathComponent(name + " extracted")
                    try await FileOperations.extract(source, to: output, progress: { _ in })
                    try expectEqual(try Data(contentsOf: output.appendingPathComponent(member)), Data(expected.utf8))
                    try expectEqual(try Data(contentsOf: source), original)
                }
            }
        }

        await runner.testAsync("P1 real LZMA1 and LZMA2 7Z archives decode the same bounded payload") {
            try await withDocumentFixture { directory in
                let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/Archives")
                var decoded: [Data] = []
                for codec in ["lzma1", "lzma2"] {
                    let source = fixtures.appendingPathComponent("test_read_format_7zip_\(codec).7z")
                    let original = try Data(contentsOf: source)
                    let entries = try SafeArchive.inspect(source)
                    try expectEqual(entries.map(\.path), ["file1"])
                    try expectEqual(entries.map(\.size), [2844])
                    let output = directory.appendingPathComponent(codec)
                    try await FileOperations.extract(source, to: output, progress: { _ in })
                    let data = try Data(contentsOf: output.appendingPathComponent("file1"))
                    try expectEqual(data.count, 2844)
                    try expect(data.starts(with: Data("The libarchive distribution ".utf8)), "upstream payload prefix")
                    try expectEqual(try Data(contentsOf: source), original)
                    decoded.append(data)
                }
                try expectEqual(decoded[0], decoded[1], "both codecs preserve complete payload")
            }
        }

        await runner.testAsync("P1 extraction rejects traversal links malformed data conflicts and size bombs atomically") {
            try await withDocumentFixture { directory in
                try expect(SafeArchive.isAvailable, "system archive backend")
                let fixtures: [(String, Data)] = [
                    ("traversal.tar", tarFixture(path: "../escaped.txt")),
                    ("absolute.tar", tarFixture(path: "/tmp/escaped.txt")),
                    ("symlink.tar", tarFixture(path: "link", data: Data(), type: 50, link: "../outside")),
                    ("hardlink.tar", tarFixture(path: "link", data: Data(), type: 49, link: "../outside")),
                    ("broken.zip", Data("not an archive".utf8)),
                ]
                for (name, data) in fixtures {
                    let source = directory.appendingPathComponent(name)
                    try data.write(to: source)
                    let output = directory.appendingPathComponent(name + " output")
                    do {
                        try SafeArchive.extract(source, to: output, progress: { _ in })
                        throw TestFailure(description: "unsafe archive accepted: \(name)")
                    } catch is YuzuError {}
                    try expect(!FileManager.default.fileExists(atPath: output.path), "failure is atomic")
                }
                let archive = directory.appendingPathComponent("large.tar")
                try tarFixture(path: "large.txt", data: Data(repeating: 65, count: 1024)).write(to: archive)
                var limits = ArchiveLimits()
                limits.totalBytes = 16
                do {
                    try SafeArchive.extract(archive, to: directory.appendingPathComponent("bomb"), limits: limits, progress: { _ in })
                    throw TestFailure(description: "size budget ignored")
                } catch is YuzuError {}
                let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
                try expect(!contents.contains { $0.hasPrefix(".yuzu-") }, "staging cleaned after failures")
            }
        }

        await runner.testAsync("P1 encrypted ZIP refuses extraction and cancellation preserves archive") {
            try await withDocumentFixture { directory in
                let source = directory.appendingPathComponent("file.txt")
                try Data("secret fixture".utf8).write(to: source)
                let archive = directory.appendingPathComponent("encrypted.zip")
                let result = try await Shell.run("/usr/bin/zip", ["-q", "-P", "test-fixture-password", archive.path, "file.txt"], currentDirectory: directory)
                try expect(result.succeeded, "encrypted fixture created")
                let original = try Data(contentsOf: archive)
                let output = directory.appendingPathComponent("output")
                do {
                    try SafeArchive.extract(archive, to: output, progress: { _ in })
                    throw TestFailure(description: "encrypted archive accepted")
                } catch is YuzuError {}
                let task = Task { try await FileOperations.extract(archive, to: output, progress: { _ in }) }
                task.cancel()
                do { try await task.value; throw TestFailure(description: "cancel ignored") } catch is CancellationError {}
                try expectEqual(try Data(contentsOf: archive), original)
                try expect(!FileManager.default.fileExists(atPath: output.path), "no failed or cancelled folder")
            }
        }

        await runner.testAsync("P1 move rejects intra-selection basename collisions before changing sources") {
            try await withDocumentFixture { directory in
                let first = directory.appendingPathComponent("a")
                let second = directory.appendingPathComponent("b")
                let output = directory.appendingPathComponent("output")
                for folder in [first, second, output] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
                let files = [first, second].map { $0.appendingPathComponent("same.txt") }
                for file in files { try Data("original".utf8).write(to: file) }
                do {
                    _ = try FileOperations.move(files, to: output)
                    throw TestFailure(description: "collision accepted")
                } catch is FileActionError {}
                for file in files { try expectEqual(try String(contentsOf: file), "original") }
                let moved = try FileOperations.move([files[0]], to: output)
                try expectEqual(moved, [output.appendingPathComponent("same.txt")])
                try expect(!FileManager.default.fileExists(atPath: files[0].path), "valid move completed")
            }
        }

        runner.test("P1 archive paths and radial placement follow Actions ownership") {
            for path in ["../x", "/x", "C:/x", "x\\y", "a/../b", "a//b"] {
                do { _ = try SafeArchive.safePath(path); throw TestFailure(description: "unsafe path accepted") } catch is YuzuError {}
            }
            try expectEqual(try SafeArchive.safePath("./folder/file.txt"), "folder/file.txt")
            for ext in ["zip", "tar", "gz", "rar", "7z"] { try expect(SafeArchive.supports(URL(fileURLWithPath: "/tmp/file.\(ext)")), "format backend \(ext)") }
            let content = RadialProvider.content(for: [URL(fileURLWithPath: "/tmp/file.zip")], mode: .actions)
            try expect(content.items.count <= 8, "radial is not crowded")
            try expect(content.items.contains { $0.action == .file(.createZIP) }, "ZIP in Actions")
            try expect(content.items.contains { $0.action == .file(.extractArchive) }, "Extract in Actions")
            try expect(content.items.contains { $0.action == .file(.quickLook) }, "Quick Look in Actions")
        }

        await runner.testAsync("P0 image outputs are parsed and mismatched destinations never commit") {
            try await withDocumentFixture { directory in
                guard
                    let context = CGContext(
                        data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                    let image = context.makeImage()
                else { throw TestFailure(description: "image fixture") }
                let source = directory.appendingPathComponent("source.png")
                try ImageIOBridge.write(image, to: source, format: .png)
                let original = try Data(contentsOf: source)
                let jpg = try await convertFixture(source, to: .jpg, in: directory)
                try await OutputValidator.validate(jpg, as: .jpg)
                do {
                    try await OutputValidator.validate(source, as: .jpg)
                    throw TestFailure(description: "PNG accepted as JPEG")
                } catch is YuzuError {}
                let wrong = directory.appendingPathComponent("wrong.jpg")
                do {
                    _ = try await Engines.convert(ConversionRequest(source: source, sourceFormat: .png, target: .tiff, destination: wrong, progress: { _ in }))
                    throw TestFailure(description: "wrong extension committed")
                } catch is YuzuError {}
                try expect(!FileManager.default.fileExists(atPath: wrong.path), "invalid output stays absent")
                try expectEqual(try Data(contentsOf: source), original, "source unchanged")
            }
        }

        await runner.testAsync("P0 transparent PNG compression preserves format with and without target size") {
            try await withDocumentFixture { directory in
                guard
                    let context = CGContext(
                        data: nil, width: 128, height: 128, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                    let image = context.makeImage()
                else { throw TestFailure(description: "image fixture") }
                let source = directory.appendingPathComponent("transparent.png")
                try ImageIOBridge.write(image, to: source, format: .png)
                let original = try Data(contentsOf: source)
                try expectEqual(Compressor.outputFormat(for: source), .png)
                for target: Int64? in [nil, 10_000] {
                    let output = directory.appendingPathComponent("compressed-\(UUID().uuidString).png")
                    try await Compressor.compress(source, preset: .balanced, resizeLongEdge: 0, targetBytes: target, to: output, progress: { _ in })
                    try await OutputValidator.validate(output, as: .png)
                }
                let wrong = directory.appendingPathComponent("wrong.jpg")
                do {
                    try await Compressor.compress(source, preset: .balanced, resizeLongEdge: 0, targetBytes: nil, to: wrong, progress: { _ in })
                    throw TestFailure(description: "mismatched output extension accepted")
                } catch is YuzuError {}
                try expectEqual(try Data(contentsOf: source), original)
                try expect(!FileManager.default.fileExists(atPath: wrong.path), "no invalid output")
            }
        }

        runner.test("P0 capability parsing never infers encoders from executable existence") {
            let encoders = BackendCapabilities.names(
                in: "Encoders:\n V..... libwebp WebP\n V..... libaom-av1 AV1\n A..... aac AAC\n ------\n V..... = Video", flagCount: 6)
            try expectEqual(encoders, ["libwebp", "libaom-av1", "aac"])
            let muxers = BackendCapabilities.names(in: " E webp WebP\n E matroska,webm Matroska\n D bad Not a muxer", flagCount: 1)
            try expect(muxers.contains("webp") && muxers.contains("webm"), "muxer aliases")
            var absent = BackendCapabilities(ffmpegPath: "/fixture/ffmpeg")
            absent.bundledWebPAvailable = false
            if !ImageIOBridge.canEncodeNatively(.webp) { try expect(!absent.canEncodeImage(.webp), "existence is insufficient") }
            absent.encoders = ["libwebp"]
            absent.decoders = ["png"]
            absent.muxers = ["webp"]
            try expect(absent.canEncodeImage(.webp), "explicit encoder decoder and muxer permit WebP")
            try expect(!absent.supports(from: .zip, to: .tar), "archive operations never appear in Convert")
            try expect(!absent.supports(from: .docx, to: .pdf), "missing Office hidden")
            try expect(!absent.supports(from: .mp4, to: .webm), "missing media encoder hidden")
        }

        await runner.testAsync("P0 WebP converts PNG JPEG and HEIC through actual available backend") {
            let capabilities = await RuntimeCapabilities.refresh()
            guard capabilities.canEncodeImage(.webp) else {
                print("  SKIP WebP integration: no native encoder, cwebp, or FFmpeg libwebp")
                return
            }
            try await withDocumentFixture { directory in
                guard
                    let context = CGContext(
                        data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                    let image = context.makeImage()
                else { throw TestFailure(description: "image fixture") }
                for format: FileFormat in [.png, .jpg, .heic] {
                    guard ImageIOBridge.canEncodeNatively(format) else { print("  SKIP \(format) fixture encoder unavailable"); continue }
                    let source = directory.appendingPathComponent("input.\(format.fileExtension)")
                    try ImageIOBridge.write(image, to: source, format: format)
                    let before = try Data(contentsOf: source)
                    try expect(BundledWebP.isAvailable, "bundled encoder is mandatory in supported builds")
                    let bundled = directory.appendingPathComponent("bundled-\(format.rawValue).webp")
                    try BundledWebP.write(ImageIOBridge.load(source), to: bundled, quality: 0.9)
                    try await OutputValidator.validate(bundled, as: .webp)
                    let output = try await convertFixture(source, to: .webp, in: directory)
                    let data = try Data(contentsOf: output)
                    try expect(data.starts(with: Array("RIFF".utf8)) && data.dropFirst(8).starts(with: Array("WEBP".utf8)), "actual WebP signature")
                    try await OutputValidator.validate(output, as: .webp)
                    try expectEqual(try Data(contentsOf: source), before, "source preserved")
                }
            }
        }

        runner.test("P0 radial hides absent optional backends and keeps native conversions") {
            var capabilities = BackendCapabilities()
            capabilities.bundledWebPAvailable = false
            let docx = URL(fileURLWithPath: "/tmp/input.docx")
            try expect(RadialProvider.content(for: [docx], mode: .conversion, capabilities: capabilities).items.isEmpty, "Office unavailable")
            let jpg = URL(fileURLWithPath: "/tmp/input.jpg")
            let items = RadialProvider.content(for: [jpg], mode: .conversion, capabilities: capabilities).items
            try expect(items.contains { $0.action == .convert(.png) }, "native PNG remains available")
            try expect(items.contains { $0.action == .convert(.pdf) }, "native PDF remains available")
            if !ImageIOBridge.canEncodeNatively(.webp) { try expect(!items.contains { $0.action == .convert(.webp) }, "unavailable WebP hidden") }
            let archive = URL(fileURLWithPath: "/tmp/input.zip")
            try expect(RadialProvider.content(for: [archive], mode: .conversion, capabilities: capabilities).items.isEmpty, "archives only in Actions")
        }

        runner.test("P0 private clipboard round trips single multi-file folders and paths without stale URLs") {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("yuzu-clipboard-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let file = directory.appendingPathComponent("é 🍋 file.txt")
            try Data().write(to: file)
            let board = NSPasteboard.withUniqueName()
            defer { board.releaseGlobally() }
            for urls in [[file], [file, directory]] {
                try FileClipboard.write(urls, pathsOnly: false, to: board)
                try expectEqual(DragMonitor.fileURLs(on: board), urls.map(\.standardizedFileURL), "native file URLs")
                try FileClipboard.write(urls, pathsOnly: true, to: board)
                try expectEqual(board.string(forType: .string), urls.map(\.path).joined(separator: "\n"))
                try expect(DragMonitor.fileURLs(on: board).isEmpty, "Copy Path removes stale file types")
            }
            do {
                try FileClipboard.write([directory.appendingPathComponent("missing")], pathsOnly: false, to: board)
                throw TestFailure(description: "stale selection copied")
            } catch is YuzuError {}
        }

        await runner.testAsync("P0 invalid staged data cancellation and symlink destinations preserve source") {
            try await withDocumentFixture { directory in
                let source = directory.appendingPathComponent("source.txt")
                try Data("original".utf8).write(to: source)
                let destination = directory.appendingPathComponent("output.png")
                do {
                    try await OutputTransaction.write(source: source, destination: destination, format: .png) { staging in
                        try Data("not an image".utf8).write(to: staging)
                    }
                    throw TestFailure(description: "invalid output committed")
                } catch is YuzuError {}
                try expect(!FileManager.default.fileExists(atPath: destination.path), "no invalid commit")
                let task = Task {
                    try await OutputTransaction.write(source: source, destination: destination, format: .png) { _ in
                        try await Task.sleep(nanoseconds: 10_000_000_000)
                    }
                }
                task.cancel()
                do { try await task.value; throw TestFailure(description: "cancel succeeded") } catch is CancellationError {}
                try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: source)
                do {
                    try await OutputTransaction.write(source: source, destination: destination, format: .png) { _ in }
                    throw TestFailure(description: "symlink destination accepted")
                } catch is YuzuError {}
                try expectEqual(try String(contentsOf: source), "original")
                let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
                try expect(!files.contains { $0.hasPrefix(".yuzu-") }, "staging removed")
            }
        }

        runner.test("conversion matrix has 305 options") {
            try expectEqual(ConversionMatrix.totalConversions, 305)
        }

        runner.test("32 advanced tools") {
            try expectEqual(ToolID.total, 32)
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
            try expectEqual(ConversionMatrix.targets(for: .gif), FileFormat.video + [.webp])
        }

        runner.test("PDF, TXT, subtitle and archive targets") {
            try expectEqual(ConversionMatrix.targets(for: .pdf), [.docx, .pptx, .xlsx, .jpg, .png, .epub, .txt, .md, .svg])
            try expectEqual(ConversionMatrix.targets(for: .txt), [.pdf, .jpg, .png, .srt, .vtt, .docx, .md, .epub, .html])
            try expectEqual(ConversionMatrix.targets(for: .srt), [.vtt, .txt])
            try expectEqual(ConversionMatrix.targets(for: .zip), [.tar, .gz])
            try expectEqual(ConversionMatrix.targets(for: .docx), [.pdf, .md, .txt, .epub, .html])
        }

        runner.test("mixed selection intersects targets") {
            try expectEqual(ConversionMatrix.targets(for: [.jpg, .webp]), [.png, .heic, .tiff, .avif, .bmp, .pdf, .ico, .icns])
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
            try expectEqual(ConversionMatrix.targets(for: .html), [.pdf, .docx, .txt], "HTML offline text exports")
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
            try expectEqual(ToolID.available(for: [.pdf]).count, 8)
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

        runner.test("radial sound plays only for fresh selections and limits rapid sweeps") {
            var gate = RadialSoundGate()
            try expect(!gate.shouldPlay(selection: nil, enabled: true, now: 0), "hub stays silent")
            try expect(gate.shouldPlay(selection: 0, enabled: true, now: 0), "first wedge clicks")
            try expect(!gate.shouldPlay(selection: 0, enabled: true, now: 0.1), "repeated native updates stay silent")
            try expect(!gate.shouldPlay(selection: 1, enabled: true, now: 0.02), "fast sweep is limited")
            try expect(gate.shouldPlay(selection: 2, enabled: true, now: 0.06), "next distinct wedge clicks")
            try expect(!gate.shouldPlay(selection: nil, enabled: true, now: 0.12), "leaving the ring stays silent")
            try expect(gate.shouldPlay(selection: 2, enabled: true, now: 0.13), "re-entering a wedge clicks")
            try expect(!gate.shouldPlay(selection: 3, enabled: false, now: 0.2), "mute suppresses feedback")
            try expect(!gate.shouldPlay(selection: 3, enabled: true, now: 0.3), "unmuting does not replay stationary hover")
            try expect(gate.shouldPlay(selection: 4, enabled: true, now: 0.4), "new selection works after unmuting")
        }

        runner.test("radial sound defaults on and persists mute preference") {
            let suite = "yuzu-sound-tests-\(UUID().uuidString)"
            guard let defaults = UserDefaults(suiteName: suite) else {
                throw TestFailure(description: "cannot create isolated preferences")
            }
            defer { defaults.removePersistentDomain(forName: suite) }
            let settings = AppSettings(defaults: defaults)
            try expect(settings.radialSoundEnabled, "feedback starts enabled")
            settings.radialSoundEnabled = false
            try expect(!AppSettings(defaults: defaults).radialSoundEnabled, "mute survives a new settings instance")
            settings.radialSoundEnabled = true
            try expect(AppSettings(defaults: defaults).radialSoundEnabled, "feedback can be enabled again")
        }

        runner.test("synthesized radial click decodes as a short quiet sound") {
            guard let sound = NSSound(data: RadialSelectionSound.clickData()) else {
                throw TestFailure(description: "generated click is not valid audio")
            }
            try expect(abs(sound.duration - 0.03) < 0.002, "click lasts thirty milliseconds")
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
                    if case .more = $0.action { return true }
                    return false
                }, "conversion mode contains only conversion actions")

            let tools = RadialProvider.content(for: [image], mode: .tools)
            try expect(!tools.items.isEmpty, "jpg tools are available")
            try expect(
                tools.items.allSatisfy {
                    if case .tool = $0.action { return true }
                    if case .more = $0.action { return true }
                    return false
                }, "tools mode contains only tool actions")

            let actions = RadialProvider.content(for: [image, directory], mode: .actions)
            try expect(actions.items.contains { $0.action == .file(.copy) }, "copy supports files and folders")
            try expect(actions.items.contains { $0.action == .file(.copyPath) }, "copy path supports files and folders")
            try expect(actions.items.contains { $0.action == .file(.move) }, "move supports files and folders")

            let flow = RadialProvider.content(for: [image], mode: .flow)
            try expect(flow.items.contains { $0.action == .task(.smartOrganize) }, "Tasks has dedicated organize preview")
            try expect(!flow.items.contains { $0.action == .tool(.compress) }, "Tasks has no compression alias")
            try expect(!flow.items.contains { $0.action == .file(.rename) }, "single rename stays in Actions")
        }

        runner.test("file actions use available system symbols") {
            for action in RadialFileAction.allCases {
                let item = RadialItem(fileAction: action)
                try expect(
                    NSImage(systemSymbolName: item.symbol, accessibilityDescription: item.detail) != nil,
                    "\(action.title) needs an available SF Symbol: \(item.symbol)")
            }
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
