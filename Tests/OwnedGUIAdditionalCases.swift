import AppKit
import Foundation
import PDFKit
import SwiftUI

@MainActor
extension OwnedGUIValidation {
    static func selectRow(_ query: String, in window: NSWindow) async throws {
        guard let root = window.contentView else { throw TestFailure(description: "list window content missing") }
        try await wait("selectable row " + query) { elements(root).contains { $0.id == query || $0.text.contains(query) } }
        for table in elements(root).compactMap({ $0.object as? NSOutlineView }) {
            for row in 0..<table.numberOfRows {
                guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true) else { continue }
                if elements(cell).contains(where: { $0.id == query || $0.text.contains(query) }) {
                    table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                    try await Task.sleep(nanoseconds: 100_000_000)
                    return
                }
            }
        }
        guard let node = elements(root).first(where: { $0.id == query || $0.text.contains(query) }) else { throw TestFailure(description: "row missing") }
        try setSelected(node)
        try await Task.sleep(nanoseconds: 100_000_000)
    }

    static func menuChoice(_ query: String, title: String, in window: NSWindow) async throws {
        let control = try await control(query, in: window)
        var candidates = [control.object]
        for _ in 0..<8 {
            guard let parent = Element(candidates[candidates.count - 1]).value("accessibilityParent") as? NSObject else { break }
            candidates.append(parent)
        }
        if let view = control.object as? NSView { candidates += elements(view).map(\.object) }
        if let root = window.contentView { candidates += elements(root).map(\.object) }
        for object in candidates {
            if let popup = object as? NSPopUpButton, let item = popup.item(withTitle: title) {
                popup.selectItem(withTitle: item.title)
                if let action = popup.action { popup.sendAction(action, to: popup.target) }
                try await Task.sleep(nanoseconds: 100_000_000)
                return
            }
            if let menu = Element(object).value("menu") as? NSMenu, let item = menu.item(withTitle: title) {
                menu.performActionForItem(at: menu.index(of: item))
                try await Task.sleep(nanoseconds: 100_000_000)
                return
            }
        }
        // SwiftUI Menu builds its native menu lazily. Queue type-selection and
        // Return in this application's event queue, never the system event tap.
        var pressing = true
        let selection = Timer(timeInterval: 0.08, repeats: false) { _ in
            MainActor.assumeIsolated {
                for character in title.lowercased() {
                    if let event = NSEvent.keyEvent(
                        with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil, characters: String(character), charactersIgnoringModifiers: String(character),
                        isARepeat: false, keyCode: 0)
                    {
                        NSApp.postEvent(event, atStart: false)
                    }
                }
                if let enter = NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)
                {
                    NSApp.postEvent(enter, atStart: false)
                }
            }
        }
        let escape = Timer(timeInterval: 1, repeats: false) { _ in
            MainActor.assumeIsolated {
                if pressing,
                    let event = NSEvent.keyEvent(
                        with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false,
                        keyCode: 53)
                {
                    NSApp.postEvent(event, atStart: false)
                }
            }
        }
        for mode: RunLoop.Mode in [.common, .eventTracking, .modalPanel] { RunLoop.main.add(selection, forMode: mode); RunLoop.main.add(escape, forMode: mode) }
        try control.press()
        pressing = false
        try await Task.sleep(nanoseconds: 400_000_000)
        selection.invalidate(); escape.invalidate()
    }

    static func registerAdditionalFeatures(_ runner: TestRunner) async {
        await runner.testAsync("GUI Open With launches an actual registered editor in a separate inactive instance and reports a missing file") {
            try await withDocumentFixture { directory in
                defer { cleanupFeatures() }
                let files = ["first.txt", "second.txt"].map { directory.appendingPathComponent($0) }
                for file in files { try Data("Open With GUI fixture".utf8).write(to: file) }
                let before = Set(NSWorkspace.shared.runningApplications.map(\.processIdentifier))
                let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
                let window = FeatureWindows.shared.show("QA Open With") { OpenWithView(files: files) }
                try await click("openWith.TextEdit.app", in: window)
                var launched: NSRunningApplication?
                try await wait("new background text editor", timeout: 20) {
                    launched = NSWorkspace.shared.runningApplications.first {
                        $0.bundleIdentifier == "com.apple.TextEdit" && !before.contains($0.processIdentifier)
                    }
                    return launched != nil
                }
                guard let editor = launched else { throw TestFailure(description: "owned editor launch missing") }
                // Only the new process created for this case is ever terminated.
                defer { if !before.contains(editor.processIdentifier) { editor.terminate() } }
                try expect(NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground, "background open preserves existing app focus")
                for file in files { try expectEqual(try TextFile.read(file), "Open With GUI fixture") }
                try FileManager.default.removeItem(at: files[1])
                try await click("openWith.TextEdit.app", in: window)
                try await wait("Open With error displayed") {
                    window.contentView.map { elements($0).contains { $0.text.contains("no longer available") } } == true
                }
            }
        }

        await runner.testAsync("GUI Smart Organize creation-month grouping and mid-operation failure roll back original files") {
            try await withDocumentFixture { directory in
                defer { cleanupFeatures() }
                let firstDir = directory.appendingPathComponent("a"), secondDir = directory.appendingPathComponent("b")
                for folder in [firstDir, secondDir] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false) }
                let first = firstDir.appendingPathComponent("first.txt"), second = secondDir.appendingPathComponent("second.txt")
                for file in [first, second] { try Data("organize source".utf8).write(to: file) }
                let window = FeatureWindows.shared.show("QA Date Organize") { TaskPanel(task: .smartOrganize, files: [first]) }
                try await click("Creation Month", in: window)
                let expected = try BatchOperations.organizePlan([first], byDate: true)[0].destination
                try await click("task.apply", in: window); try await click("task.confirm")
                _ = try await finishJobs()
                try expectEqual(try TextFile.read(expected), "organize source")
                try FileManager.default.moveItem(at: expected, to: first)
                cleanupFeatures()
                let failure = FeatureWindows.shared.show("QA Organize Rollback") { TaskPanel(task: .smartOrganize, files: [first, second]) }
                try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: secondDir.path)
                defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: secondDir.path) }
                try await click("task.apply", in: failure); try await click("task.confirm")
                let jobs = try await jobFailures()
                try expect(
                    jobs.contains {
                        if case .failed = $0.status { return true }; return false
                    }, "partial move fails visibly")
                for file in [first, second] { try expectEqual(try TextFile.read(file), "organize source") }
                try expect(!FileManager.default.fileExists(atPath: firstDir.appendingPathComponent("Document").path), "created destination rolled back")
            }
        }

        await runner.testAsync("GUI Task cancel stops a queued reviewed rename without changing sources") {
            try await withDocumentFixture { directory in
                defer { cleanupFeatures() }
                let files = ["a.txt", "b.txt"].map { directory.appendingPathComponent($0) }
                for file in files { try Data("keep".utf8).write(to: file) }
                for i in 0..<2 {
                    JobRunner.shared.run(title: "QA controlled queue", detail: "\(i)") { _ in
                        try await Task.sleep(nanoseconds: 20_000_000_000); return []
                    }
                }
                try await wait("queue occupied") { JobRunner.shared.jobs.filter { $0.status == .running }.count == 2 }
                let window = FeatureWindows.shared.show("QA Rename Cancel") { TaskPanel(task: .batchRename, files: files) }
                try await edit("rename.prefix", "changed-", in: window)
                try await click("task.apply", in: window); try await click("task.confirm")
                try await click("task.cancel", in: window)
                for file in files { try expectEqual(try TextFile.read(file), "keep") }
                try expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("changed-a.txt").path), "queued changes never published")
            }
        }

        await runner.testAsync("GUI Workflow configures steps reorders saves reloads validates and runs real operations") {
            try await withDocumentFixture { directory in
                defer { cleanupFeatures() }
                let image = directory.appendingPathComponent("workflow-source.png")
                try ImageIOBridge.write(SampleMedia.image(width: 240, height: 120, hue: 0.1), to: image, format: .png)
                let original = try Data(contentsOf: image)
                let window = FeatureWindows.shared.show("QA Workflow") { WorkflowPanel(files: [image]) }
                try await edit("Longest edge", "100", in: window)
                try await click("workflow.save", in: window)
                try await click("workflow.add", in: window)
                try await wait("invalid self-conversion detected") {
                    window.contentView.flatMap { elements($0).first { $0.id == "workflow.run" } }?.enabled == false
                }
                try await click("workflow.remove.2", in: window)
                try await click("workflow.up.1", in: window)
                try await click("workflow.up.1", in: window)
                try await edit("Longest edge", "50", in: window)
                try await click("workflow.load", in: window)
                try await click("workflow.run", in: window); try await click("workflow.confirm")
                let outputs = try await finishJobs()
                guard let output = outputs.first else { throw TestFailure(description: "workflow output") }
                try expectEqual(ImageIOBridge.pixelSize(output), CGSize(width: 100, height: 50))
                try expectEqual(try Data(contentsOf: image), original)
            }
        }

        await runner.testAsync("GUI Duplicate Finder scans hundreds of files reviews groups rescans cancels and emits Reveal selection") {
            try await withDocumentFixture { directory in
                defer { cleanupFeatures() }
                let files = (0..<250).map { directory.appendingPathComponent("duplicate-\($0).txt") }
                for file in files { try Data("identical fixture".utf8).write(to: file) }
                let window = FeatureWindows.shared.show("QA Duplicate Finder") { DuplicateFinderView(files: [directory]) }
                try await click("Find duplicates", in: window)
                try await wait("duplicate group results") {
                    window.contentView.map { elements($0).contains { $0.text.contains("250 identical files") } } == true
                }
                try await click("duplicate.reveal." + files[0].path, in: window)
                try expectEqual(ValidationRuntime.revealedSelections.last, [files[0]], "correct Reveal bridge request")
                // Sparse files keep a real streaming rescan active long enough
                // to exercise cancellation, without allocating a GiB on disk.
                for name in ["large-a.bin", "large-b.bin"] {
                    let url = directory.appendingPathComponent(name)
                    try Data().write(to: url)
                    let handle = try FileHandle(forWritingTo: url)
                    try handle.truncate(atOffset: 512 * 1024 * 1024)
                    try handle.close()
                }
                try await click("Scan again", in: window)
                try await click("Cancel scan", in: window)
                try await wait("cancelled scan becomes available again") {
                    window.contentView.flatMap { elements($0).first { $0.label == "Scan again" } }?.enabled == true
                }
                try expect(files.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }, "no duplicate deletion")
            }
        }

        await runner.testAsync("GUI File Shelf adds selects reuses removes and refreshes actual bookmark references") {
            try await withDocumentFixture { directory in
                defer { cleanupFeatures() }
                let first = directory.appendingPathComponent("first.txt"), second = directory.appendingPathComponent("second.txt")
                for file in [first, second] { try Data("shelf".utf8).write(to: file) }
                let suite = "YuzuQA-ShelfGUI-\(UUID().uuidString)"
                guard let defaults = UserDefaults(suiteName: suite) else { throw TestFailure(description: "shelf defaults") }
                defer { defaults.removePersistentDomain(forName: suite) }
                let shelf = FileShelfStore(defaults: defaults)
                var used: [URL] = []
                let window = FeatureWindows.shared.show("QA Shelf") { FileShelfView(files: [first], shelf: shelf, use: { urls, _ in used = urls }) }
                try await wait("initial shelf item") { shelf.items.count == 1 }
                ValidationRuntime.fileSelections = [[second]]
                try await click("shelf.add", in: window)
                try await wait("added shelf reference") { shelf.items.count == 2 }
                guard let reference = shelf.items.first else { throw TestFailure(description: "shelf item") }
                try await selectRow("shelf.row." + reference.id.uuidString, in: window)
                try await click("shelf.use", in: window)
                try expectEqual(used.map { $0.resolvingSymlinksInPath() }, [first.resolvingSymlinksInPath()], "Use selection passes actual reference")
                try await click("shelf.remove", in: window)
                try await wait("reference removed") { shelf.items.count == 1 }
                try expect(FileManager.default.fileExists(atPath: first.path), "remove does not delete file")
                try FileManager.default.removeItem(at: second)
                try await click("shelf.refresh", in: window)
                try expectEqual(shelf.items.count, 1, "missing reference retained")
                try await wait("missing file displayed") { window.contentView.map { elements($0).contains { $0.text.contains("Missing") } } == true }
            }
        }

        await runner.testAsync("GUI Archive Manager inspects selects nested entries and exports protected and unprotected ZIP copies") {
            try await withDocumentFixture { directory in
                defer { cleanupFeatures() }
                let folder = directory.appendingPathComponent("folder"), other = directory.appendingPathComponent("other.txt")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
                try Data("selected".utf8).write(to: folder.appendingPathComponent("member.txt"))
                try Data("excluded".utf8).write(to: other)
                let archive = directory.appendingPathComponent("manager.zip")
                try await FileOperations.createZIP([folder, other], to: archive, progress: { _ in })
                let window = FeatureWindows.shared.show("QA Archive Manager") { ArchiveActionView(files: [archive], creating: false, showAdvanced: true) }
                try await click("Inspect archive entries", in: window)
                try await selectRow("archive.row.folder", in: window)
                try await click("Export selected entries as ZIP", in: window)
                guard let exported = try await finishJobs().first else { throw TestFailure(description: "selected ZIP output") }
                let entries = try SafeArchive.inspect(exported).map(\.path)
                try expect(entries.contains("folder/member.txt") && !entries.contains("other.txt"), "only selected descendants")
                cleanupFeatures()
                let protected = FeatureWindows.shared.show("QA Protected Repack") { ArchiveActionView(files: [archive], creating: false, showAdvanced: true) }
                try await click("Inspect archive entries", in: protected)
                try await selectRow("archive.row.other.txt", in: protected)
                try await click("Protect exported ZIP copy", in: protected)
                try await edit("archive.exportPassword", "GUI-AES", in: protected)
                try await click("Export selected entries as ZIP", in: protected)
                guard let aes = try await finishJobs().first else { throw TestFailure(description: "AES repack") }
                let extracted = directory.appendingPathComponent("check-AES")
                try await FileOperations.extract(aes, to: extracted, password: "GUI-AES", progress: { _ in })
                try expectEqual(try TextFile.read(extracted.appendingPathComponent("other.txt")), "excluded")
            }
        }

        await runner.testAsync("GUI Watermark image and PDF controls commit position size opacity rotation and image selection") {
            try await withDocumentFixture { directory in
                defer { cleanupFeatures() }
                let image = directory.appendingPathComponent("source.png"), mark = directory.appendingPathComponent("mark.png")
                try ImageIOBridge.write(SampleMedia.image(width: 320, height: 180, hue: 0.2), to: image, format: .png)
                try ImageIOBridge.write(SampleMedia.image(width: 80, height: 40, hue: 0.7), to: mark, format: .png)
                let pdf = directory.appendingPathComponent("pages.pdf")
                try ImageIOBridge.writePDF(images: [try ImageIOBridge.load(image), try ImageIOBridge.load(image)], to: pdf)
                for (source, useImage) in [(image, false), (pdf, false), (image, true), (pdf, true)] {
                    cleanupFeatures()
                    let original = try Data(contentsOf: source)
                    ToolWindowManager.shared.open(.watermark, files: [source])
                    guard let window = ToolWindowManager.shared.openWindows.first else { throw TestFailure(description: "watermark window") }
                    try await edit("watermark.text", "QA TEXT", in: window)
                    for (label, value) in [("Width", 0.4), ("Opacity", 0.65), ("Rotation", 30.0)] {
                        try await control(label, in: window).set(NSNumber(value: value))
                    }
                    try await menuChoice("watermark.position", title: "Top Left", in: window)
                    if useImage {
                        ValidationRuntime.fileSelections = [[mark]]
                        try await click("Use an image watermark", in: window)
                        try await click("Choose watermark image…", in: window)
                    }
                    try await click("tool.save", in: window)
                    guard let output = try await finishJobs().first else { throw TestFailure(description: "watermark output") }
                    try await OutputValidator.validate(output, as: source.pathExtension == "pdf" ? .pdf : .png)
                    try expectEqual(try Data(contentsOf: source), original)
                    if source == pdf { try expectEqual(PDFDocument(url: output)?.pageCount, 2) }
                }
            }
        }

        await runner.testAsync("GUI File Comparison renders text differences and streams large binary content without editing inputs") {
            try await withDocumentFixture { directory in
                defer { cleanupFeatures() }
                let a = directory.appendingPathComponent("a.txt"), b = directory.appendingPathComponent("b.txt")
                try Data("first\nold line\n".utf8).write(to: a); try Data("first\nnew line\n".utf8).write(to: b)
                ToolWindowManager.shared.open(.fileComparison, files: [a, b])
                guard let textWindow = ToolWindowManager.shared.openWindows.first else { throw TestFailure(description: "comparison window") }
                try await wait("text difference summary") {
                    textWindow.contentView.map { elements($0).contains { $0.text.contains("inserted lines") } } == true
                }
                try expectEqual(try TextFile.read(a), "first\nold line\n")
                cleanupFeatures()
                let large = directory.appendingPathComponent("large.bin"), copy = directory.appendingPathComponent("copy.bin")
                try Data(repeating: 0xff, count: 2_100_000).write(to: large); try FileManager.default.copyItem(at: large, to: copy)
                ToolWindowManager.shared.open(.fileComparison, files: [large, copy])
                guard let binary = ToolWindowManager.shared.openWindows.first else { throw TestFailure(description: "binary comparison window") }
                try await wait("large binary result") { binary.contentView.map { elements($0).contains { $0.text.contains("identical SHA-256") } } == true }
                try await wait("binary comparison explanation") {
                    binary.contentView.map { elements($0).contains { $0.text.contains("Binary or large files") } } == true
                }
            }
        }
    }
}
