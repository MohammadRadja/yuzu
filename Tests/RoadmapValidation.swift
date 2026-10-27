import AppKit
import Foundation
import PDFKit

@MainActor
enum RoadmapValidation {
    static func register(_ runner: TestRunner) async {
        await runner.testAsync("Document archive reads the required literal OOXML content-types member without wildcard ambiguity") {
            try await withDocumentFixture { directory in
                let output = directory.appendingPathComponent("literal.docx")
                try await DocxWriter.write(paragraphs: ["Yuzu literal content"], images: [], to: output)
                let archive = try await DocumentArchive.open(output)
                let types = try await archive.text("[Content_Types].xml")
                try expect(types.contains("word/document.xml"), "canonical bracketed member read literally")
                try expect(try await archive.text("word/document.xml").contains("Yuzu literal content"), "native document content readable")
                let unsafe = directory.appendingPathComponent("ambiguous.epub")
                try await DocumentPackage.write(["a[1].xml": Data("ambiguous".utf8)], to: unsafe)
                do { _ = try await DocumentArchive.open(unsafe); throw TestFailure(description: "ambiguous nonstandard member accepted") } catch is YuzuError {}
            }
        }
        runner.test("Radial accessibility distinguishes format names sharing the same conversion detail") {
            let items = [FileFormat.pdf, .docx, .txt].map { RadialItem(action: .convert($0), label: $0.displayName, detail: "Text-only import", symbol: "doc") }
            try expectEqual(Set(items.map(\.accessibilityLabel)).count, 3)
            for item in items { try expect(item.accessibilityLabel.contains(item.label), "spoken format name") }
            let copy = RadialItem(fileAction: .duplicate)
            try expect(copy.accessibilityLabel.contains("Make a Copy"), "copy label is distinct from Duplicate Finder")
        }
        await runner.testAsync("Actions rename and move refuse existing targets without changing file or folder content") {
            try await withDocumentFixture { directory in
                let source = directory.appendingPathComponent("original.txt"), taken = directory.appendingPathComponent("taken.txt")
                try Data("original".utf8).write(to: source)
                try Data("existing".utf8).write(to: taken)
                do {
                    _ = try FileOperations.rename(source, to: taken.lastPathComponent); throw TestFailure(description: "rename overwrote a file")
                } catch is FileActionError {}
                for name in ["../escape", "a:b", ".", "..", ""] {
                    do { _ = try FileOperations.rename(source, to: name); throw TestFailure(description: "invalid rename accepted") } catch is YuzuError {}
                }
                let destination = directory.appendingPathComponent("destination")
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
                try Data("destination".utf8).write(to: destination.appendingPathComponent(source.lastPathComponent))
                do { _ = try FileOperations.move([source], to: destination); throw TestFailure(description: "move overwrote a file") } catch is FileActionError
                {}
                try expectEqual(try TextFile.read(source), "original")
                try expectEqual(try TextFile.read(taken), "existing")
                try expectEqual(try TextFile.read(destination.appendingPathComponent(source.lastPathComponent)), "destination")
                let renamed = try FileOperations.rename(source, to: "renamed ü.txt")
                try expectEqual(try TextFile.read(renamed), "original")
                let folder = directory.appendingPathComponent("folder")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
                try Data("nested".utf8).write(to: folder.appendingPathComponent("nested.txt"))
                let movedFolder = try FileOperations.rename(folder, to: "renamed folder")
                try expectEqual(try TextFile.read(movedFolder.appendingPathComponent("nested.txt")), "nested")
            }
        }

        await runner.testAsync("Inspect reads native file folder permissions and rejects disappeared input") {
            try await withDocumentFixture { directory in
                let source = directory.appendingPathComponent("metadata.txt")
                try Data("Yuzu".utf8).write(to: source)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: source.path)
                let info = try FileInspection.read(source)
                try expectEqual(info.size, 4)
                try expectEqual(info.type, .typeRegular)
                try expectEqual(info.permissions & 0o777, 0o600)
                try expect(info.created != nil && info.modified != nil, "native dates")
                try expectEqual(try FileInspection.read(directory).type, .typeDirectory)
                try FileManager.default.removeItem(at: source)
                do { _ = try FileInspection.read(source); throw TestFailure(description: "missing file silently inspected") } catch is TestFailure {
                    throw TestFailure(description: "missing file silently inspected")
                } catch {}
            }
        }

        await runner.testAsync("Open With intersects native registered apps and rejects missing or incompatible selections") {
            try await withDocumentFixture { directory in
                let a = directory.appendingPathComponent("a.txt"), b = directory.appendingPathComponent("b.txt")
                for source in [a, b] { try Data("open fixture".utf8).write(to: source) }
                let common = try OpenWithService.applications(for: [a, b])
                try expect(!common.isEmpty, "macOS has a registered text editor")
                try expect(
                    common.allSatisfy {
                        NSWorkspace.shared.urlsForApplications(toOpen: a).contains($0) && NSWorkspace.shared.urlsForApplications(toOpen: b).contains($0)
                    }, "intersection")
                do {
                    _ = try await OpenWithService.open([a, b], with: directory.appendingPathComponent("Missing.app"));
                    throw TestFailure(description: "incompatible app accepted")
                } catch is YuzuError {}
                try FileManager.default.removeItem(at: b)
                do { _ = try OpenWithService.applications(for: [a, b]); throw TestFailure(description: "missing selected file accepted") } catch is YuzuError {}
            }
        }

        await runner.testAsync("Shelf bookmarks follow a renamed file and persist refreshed identity across store reloads") {
            try await withDocumentFixture { directory in
                let suite = "YuzuQA-Shelf-\(UUID().uuidString)"
                guard let defaults = UserDefaults(suiteName: suite) else { throw TestFailure(description: "isolated defaults") }
                defer { defaults.removePersistentDomain(forName: suite) }
                let original = directory.appendingPathComponent("before.txt"), moved = directory.appendingPathComponent("after ü.txt")
                try Data("bookmark identity".utf8).write(to: original)
                let store = FileShelfStore(defaults: defaults)
                try store.add([original])
                try FileManager.default.moveItem(at: original, to: moved)
                store.refresh()
                let restored = FileShelfStore(defaults: defaults)
                guard var ref = restored.items.first else { throw TestFailure(description: "shelf reference missing after reload") }
                try expectEqual(ref.resolve()?.resolvingSymlinksInPath(), moved.resolvingSymlinksInPath())
                try expectEqual(URL(fileURLWithPath: ref.lastPath).resolvingSymlinksInPath(), moved.resolvingSymlinksInPath())
                restored.remove(ref.id)
                try expect(FileShelfStore(defaults: defaults).items.isEmpty, "removal persists")
                try expectEqual(try TextFile.read(moved), "bookmark identity")
            }
        }

        if OfficeEngine.executable != nil {
            await runner.testAsync("Real Pages 4 and Pages 5 inputs export valid PDF DOCX and literal text without source changes") {
                try await withDocumentFixture { directory in
                    let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/Pages")
                    for name in ["pages4-file.pages", "pages5-file.pages"] {
                        let source = fixtures.appendingPathComponent(name)
                        let original = try Data(contentsOf: source)
                        let pdf = try await convertFixture(source, to: .pdf, in: directory)
                        guard let doc = PDFDocument(url: pdf) else { throw TestFailure(description: "Pages PDF missing") }
                        try expect(doc.pageCount > 0, "actual Pages document parsed")
                        let text = try await convertFixture(source, to: .txt, in: directory)
                        let extracted = try TextFile.read(text)
                        if name == "pages4-file.pages" {
                            // This upstream detection fixture is a blank document;
                            // Lorem ipsum in index.xml belongs to template styles.
                            try expectEqual(doc.pageCount, 1)
                            try expect(extracted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "blank Pages content remains blank")
                        } else {
                            try expect(extracted.contains("My hovercraft is full of eels."), "actual Pages 5 text")
                            try expect(extracted.contains("vznášedlo") && extracted.contains("poduszkowiec"), "Unicode text retained")
                            try expect(doc.string?.contains("My hovercraft") == true, "PDF text retained")
                        }
                        let docx = try await convertFixture(source, to: .docx, in: directory)
                        try await OutputValidator.validate(docx, as: .docx)
                        try expectEqual(try Data(contentsOf: source), original)
                    }
                }
            }
        }
    }

    static func nativeOnly(_ runner: TestRunner) async {
        await runner.testAsync("Native-only runtime has no FFmpeg ffprobe cwebp or LibreOffice route") {
            let capabilities = await RuntimeCapabilities.refresh()
            try expect(FFmpeg.path == nil && FFmpeg.probePath == nil && OfficeEngine.executable == nil, "optional executables disabled")
            try expect(capabilities.ffmpegPath == nil && capabilities.cwebpPath == nil && !capabilities.officeAvailable, "runtime probe agrees")
            try expect(!capabilities.supports(from: .docx, to: .pdf), "Office hidden")
            try expect(!capabilities.supports(tool: .audioChannels, formats: [.wav]), "FFmpeg-only tool hidden")
        }
        await runner.testAsync("Native-only real image WebP PDF OCR archive and workflow outputs validate without optional tools") {
            try await withDocumentFixture { directory in
                let image = directory.appendingPathComponent("native.png")
                try ImageIOBridge.write(SampleMedia.image(width: 640, height: 320, hue: 0.2), to: image, format: .png)
                for target: FileFormat in [.jpg, .heic, .webp, .ico, .icns, .pdf] {
                    let output = try await convertFixture(image, to: target, in: directory)
                    try await OutputValidator.validate(output, as: target)
                }
                let text = try await OCROps.text(image, progress: { _ in })
                try expect(text.localizedCaseInsensitiveContains("Yuzu"), "local Vision works without executables")
                let archive = directory.appendingPathComponent("native.zip")
                try await FileOperations.createZIP([image], to: archive, progress: { _ in })
                let extracted = directory.appendingPathComponent("extracted")
                try await FileOperations.extract(archive, to: extracted, progress: { _ in })
                try expectEqual(try Data(contentsOf: extracted.appendingPathComponent(image.lastPathComponent)), Data(contentsOf: image))
                let output = directory.appendingPathComponent("workflow.png")
                try await WorkflowEngine.run(
                    image, steps: [WorkflowStep(kind: .resize, longEdge: 120), WorkflowStep(kind: .optimize)], to: output, progress: { _ in })
                try await OutputValidator.validate(output, as: .png)
            }
        }
    }

    static func volumeLifecycle(_ runner: TestRunner) async {
        await runner.testAsync("Shelf persists bookmarks across a detached remounted private disk image and fresh process") {
            try await withDocumentFixture { directory in
                let image = directory.appendingPathComponent("shelf.dmg"), mount = directory.appendingPathComponent("mounted")
                let suite = "YuzuQA-Volume-\(UUID().uuidString)"
                guard let defaults = UserDefaults(suiteName: suite) else { throw TestFailure(description: "volume defaults") }
                defer { defaults.removePersistentDomain(forName: suite) }
                let create = try await Shell.run(
                    "/usr/bin/hdiutil", ["create", "-quiet", "-size", "32m", "-fs", "HFS+", "-volname", "YuzuQA-Shelf", "-type", "UDIF", image.path])
                try expect(create.succeeded, "private disk image creation: \(create.stdout) \(create.stderr)")
                func attach() async throws {
                    try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
                    let result = try await Shell.run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-noautoopen", "-mountpoint", mount.path, image.path])
                    try expect(result.succeeded, "private image mount: \(result.stderr)")
                }
                func detach() async throws {
                    let result = try await Shell.run("/usr/bin/hdiutil", ["detach", mount.path])
                    if !result.succeeded {
                        let forced = try await Shell.run("/usr/bin/hdiutil", ["detach", "-force", mount.path])
                        try expect(forced.succeeded, "private image detach: \(forced.stderr)")
                    }
                }
                var mounted = false
                do {
                    try await attach(); mounted = true
                    let source = mount.appendingPathComponent("before.txt"), moved = mount.appendingPathComponent("after.txt")
                    try Data("shelf mounted fixture".utf8).write(to: source)
                    let store = FileShelfStore(defaults: defaults)
                    try store.add([source])
                    try FileManager.default.moveItem(at: source, to: moved)
                    store.refresh()
                    try await detach(); mounted = false
                    store.refresh()
                    guard var missing = store.items.first else { throw TestFailure(description: "missing reference was dropped") }
                    try expectEqual(missing.resolve(), nil, "withoutMounting does not remount the image")
                    try await attach(); mounted = true
                    store.refresh()
                    guard var restored = store.items.first else { throw TestFailure(description: "reference not retained") }
                    try expectEqual(restored.resolve()?.resolvingSymlinksInPath(), moved.resolvingSymlinksInPath())
                    defaults.synchronize()
                    let child = try await Shell.run(ProcessInfo.processInfo.arguments[0], ["--qa-shelf-reopen", suite, moved.path])
                    try expect(
                        child.succeeded && child.stdout.contains("1/1 passed"), "fresh process resolves persisted bookmark: \(child.stdout) \(child.stderr)")
                    try await detach(); mounted = false
                } catch {
                    if mounted { try? await detach() }
                    throw error
                }
            }
        }
    }

    static func reopenedShelf(_ runner: TestRunner) {
        runner.test("reopened process resolves the persisted shelf reference") {
            let args = ProcessInfo.processInfo.arguments
            guard args.count == 4, args[2].hasPrefix("YuzuQA-"), let defaults = UserDefaults(suiteName: args[2]),
                var reference = FileShelfStore(defaults: defaults).items.first
            else { throw TestFailure(description: "invalid shelf child configuration") }
            let expected = URL(fileURLWithPath: args[3]).resolvingSymlinksInPath()
            try expectEqual(reference.resolve()?.resolvingSymlinksInPath(), expected)
            try expectEqual(try TextFile.read(expected), "shelf mounted fixture")
        }
    }
}
