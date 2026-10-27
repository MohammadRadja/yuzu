import AppKit
import ImageIO
import PDFKit
import SwiftUI

@MainActor
extension OwnedGUIValidation {
    static func occupyQueue() async throws {
        for index in 0..<2 {
            JobRunner.shared.run(title: "QA queue gate", detail: "\(index)") { _ in
                try await Task.sleep(nanoseconds: 30_000_000_000)
                return []
            }
        }
        try await wait("controlled queue gates") { JobRunner.shared.jobs.filter { $0.status == .running }.count == 2 }
    }

    static func cancelUsingHUD() async throws {
        guard let hud = NSApp.windows.first(where: { $0 is JobHUDPanel && $0.isVisible }),
            let close = hud.standardWindowButton(.closeButton)
        else { throw TestFailure(description: "owned progress cancellation control missing") }
        let jobs = JobRunner.shared.jobs
        close.performClick(nil)
        for job in jobs { await job.task?.value }
        try expect(jobs.allSatisfy { $0.status == .cancelled }, "native progress close cancels only owned queued jobs")
    }

    static func registerCancellationCases(_ runner: TestRunner) async {
        await runner.testAsync("GUI New Folder with Selection native confirmation cancels safely then groups the actual files") {
            try await withDocumentFixture { directory in
                defer { cleanupFeatures() }
                let files = ["first.txt", "second.txt"].map { directory.appendingPathComponent($0) }
                for file in files { try Data(file.lastPathComponent.utf8).write(to: file) }
                let handler = FileActionHandler()
                for cancel in [true, false] {
                    var responded = false
                    var failure: String?
                    let deadline = Date().addingTimeInterval(5)
                    let responder = Timer(timeInterval: 0.03, repeats: true) { timer in
                        MainActor.assumeIsolated {
                            guard
                                let root = NSApp.windows.first(where: { window in
                                    window.isVisible
                                        && window.contentView.map { elements($0).contains { $0.text.contains("New Folder with Selection") } } == true
                                })?.contentView
                            else {
                                if Date() > deadline { NSApp.abortModal(); timer.invalidate() }
                                return
                            }
                            let nodes = elements(root)
                            guard let field = nodes.compactMap({ $0.object as? NSTextField }).first(where: \.isEditable),
                                let button = nodes.compactMap({ $0.object as? NSButton }).first(where: { $0.title == (cancel ? "Cancel" : "Create and Move") })
                            else { return }
                            field.stringValue = "Reviewed Group"
                            responded = true; timer.invalidate(); button.performClick(nil)
                        }
                    }
                    for mode: RunLoop.Mode in [.common, .modalPanel] { RunLoop.main.add(responder, forMode: mode) }
                    handler.perform(.newFolder, urls: files) { failure = $0 }
                    responder.invalidate()
                    try expect(responded && failure == nil, "owned native grouping confirmation responded")
                    if cancel {
                        try expect(JobRunner.shared.jobs.isEmpty, "cancel does not enqueue moves")
                        for file in files { try expectEqual(try TextFile.read(file), file.lastPathComponent) }
                    } else {
                        guard let folder = try await finishJobs().first else { throw TestFailure(description: "grouped folder output") }
                        try expectEqual(folder.lastPathComponent, "Reviewed Group")
                        for file in files {
                            try expectEqual(try TextFile.read(folder.appendingPathComponent(file.lastPathComponent)), file.lastPathComponent)
                            try expect(!FileManager.default.fileExists(atPath: file.path), "confirmed move completed")
                        }
                    }
                }
            }
        }

        await runner.testAsync("GUI Rename native dialog rejects an existing name and Move reports destination conflicts") {
            try await withDocumentFixture { directory in
                defer { cleanupFeatures() }
                let source = directory.appendingPathComponent("original.txt"), taken = directory.appendingPathComponent("taken.txt")
                try Data("original".utf8).write(to: source)
                try Data("existing".utf8).write(to: taken)
                var error: String?, responded = false
                let handler = FileActionHandler()
                let deadline = Date().addingTimeInterval(5)
                let responder = Timer(timeInterval: 0.05, repeats: true) { timer in
                    MainActor.assumeIsolated {
                        guard
                            let alert = NSApp.windows.first(where: { window in
                                window.isVisible && window.contentView.map { elements($0).contains { $0.text.contains("Rename Item") } } == true
                            }), let root = alert.contentView
                        else {
                            if Date() > deadline { NSApp.abortModal(); timer.invalidate() }
                            return
                        }
                        guard let field = elements(root).compactMap({ $0.object as? NSTextField }).first(where: \.isEditable),
                            let button = elements(root).compactMap({ $0.object as? NSButton }).first(where: { $0.title == "Rename" })
                        else { return }
                        field.stringValue = taken.lastPathComponent
                        responded = true; timer.invalidate(); button.performClick(nil)
                    }
                }
                for mode: RunLoop.Mode in [.common, .modalPanel] { RunLoop.main.add(responder, forMode: mode) }
                defer { responder.invalidate() }
                handler.perform(.rename, urls: [source]) { error = $0 }
                try await wait("native Rename response") { responded && error != nil }
                try expect(error?.contains("already exists") == true, "Rename returns actionable collision")
                let target = directory.appendingPathComponent("destination")
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
                try Data("destination".utf8).write(to: target.appendingPathComponent(source.lastPathComponent))
                ValidationRuntime.fileSelections = [[target]]
                try await choose(.file(.move), files: [source], mode: .actions)
                let jobs = try await jobFailures()
                try expect(
                    jobs.contains {
                        if case .failed(let text) = $0.status { return text.contains("already exists") }; return false
                    }, "Move collision retained in HUD")
                try expectEqual(try TextFile.read(source), "original")
                try expectEqual(try TextFile.read(taken), "existing")
                try expectEqual(try TextFile.read(target.appendingPathComponent(source.lastPathComponent)), "destination")
            }
        }

        await runner.testAsync("GUI Batch Optimize displays live total and per-file progress and cancels active work preserving originals") {
            try await withDocumentFixture { directory in
                defer { cleanupFeatures() }
                let seed = directory.appendingPathComponent("seed.png")
                try ImageIOBridge.write(SampleMedia.image(width: 1800, height: 900, hue: 0.3), to: seed, format: .png)
                let original = try Data(contentsOf: seed)
                let files = (0..<30).map { directory.appendingPathComponent("image-\($0).png") }
                for file in files { try FileManager.default.copyItem(at: seed, to: file) }
                let window = FeatureWindows.shared.show("QA Optimize Cancel") { TaskPanel(task: .batchOptimize, files: files) }
                try await click("task.apply", in: window); try await click("task.confirm")
                try await wait("total and current file progress") {
                    let nodes = window.contentView.map { elements($0) } ?? []
                    return nodes.contains { $0.text.contains("Total:") } && nodes.contains { $0.text.contains("Processing:") }
                }
                let jobs = JobRunner.shared.jobs
                try await click("task.cancel", in: window)
                for job in jobs { await job.task?.value }
                try expect(jobs.contains { $0.status == .cancelled }, "active optimization cancelled")
                for file in files { try expectEqual(try Data(contentsOf: file), original) }
                let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
                try expect(!contents.contains { $0.hasPrefix(".yuzu-") }, "no abandoned staged output")
            }
        }

        await runner.testAsync("GUI OCR exports both scanned PDF pages and its queued job can be cancelled from native progress") {
            try await withDocumentFixture { directory in
                defer { cleanupFeatures() }
                let pdf = directory.appendingPathComponent("scan.pdf")
                let frame = SampleMedia.image(width: 640, height: 320, hue: 0.2)
                try ImageIOBridge.writePDF(images: [frame, frame], to: pdf)
                let original = try Data(contentsOf: pdf)
                ToolWindowManager.shared.open(.ocr, files: [pdf])
                guard let window = ToolWindowManager.shared.openWindows.first else { throw TestFailure(description: "OCR window") }
                try await click("tool.save", in: window)
                guard let output = try await finishJobs().first else { throw TestFailure(description: "OCR TXT") }
                let text = try TextFile.read(output).lowercased()
                try expect(text.components(separatedBy: "yuzu").count >= 3, "text recognized from both raster pages")
                cleanupFeatures(); try await occupyQueue()
                ToolWindowManager.shared.open(.ocr, files: [pdf])
                try await click("tool.save")
                try await cancelUsingHUD()
                try expectEqual(try Data(contentsOf: pdf), original)
            }
        }

        await runner.testAsync("GUI Upscale 2x renders correct dimensions rejects oversized output and supports queued cancellation") {
            try await withDocumentFixture { directory in
                defer { cleanupFeatures() }
                let source = directory.appendingPathComponent("small.png")
                try ImageIOBridge.write(SampleMedia.image(width: 100, height: 50, hue: 0.2), to: source, format: .png)
                ToolWindowManager.shared.open(.upscaleImage, files: [source])
                try await click("2×"); try await click("tool.save")
                guard let output = try await finishJobs().first else { throw TestFailure(description: "2x output") }
                try expectEqual(ImageIOBridge.pixelSize(output), CGSize(width: 200, height: 100))
                try expect(NSImage(contentsOf: output)?.isValid == true, "AppKit decodes displayed result")
                cleanupFeatures()
                let large = directory.appendingPathComponent("large.png")
                try ImageIOBridge.write(SampleMedia.image(width: 2600, height: 2500, hue: 0.2), to: large, format: .png)
                ToolWindowManager.shared.open(.upscaleImage, files: [large])
                try await click("4×"); try await click("tool.save")
                let failed = try await jobFailures()
                try expect(
                    failed.contains {
                        if case .failed(let error) = $0.status { return error.contains("100 megapixels") }; return false
                    }, "size limit visible in HUD")
                cleanupFeatures(); try await occupyQueue()
                ToolWindowManager.shared.open(.upscaleImage, files: [source])
                try await click("tool.save"); try await cancelUsingHUD()
            }
        }

        await runner.testAsync("GUI Archive Workflow and GIF progress cancellation leaves sources intact and archive panel ready for retry") {
            try await withDocumentFixture { directory in
                defer { cleanupFeatures() }
                let source = directory.appendingPathComponent("source.png")
                try ImageIOBridge.write(SampleMedia.image(width: 120, height: 80, hue: 0.3), to: source, format: .png)
                let original = try Data(contentsOf: source)
                let archive = directory.appendingPathComponent("extract-input.zip")
                try await FileOperations.createZIP([source], to: archive, progress: { _ in })
                let archiveData = try Data(contentsOf: archive)
                for kind in 0..<4 {
                    cleanupFeatures(); try await occupyQueue()
                    let window: NSWindow
                    if kind == 0 {
                        window = FeatureWindows.shared.show("QA Cancel ZIP") { ArchiveActionView(files: [source], creating: true) }
                        try await click("Create ZIP", in: window)
                    } else if kind == 1 {
                        window = FeatureWindows.shared.show("QA Cancel Extract") { ArchiveActionView(files: [archive], creating: false) }
                        try await click("Extract all", in: window)
                    } else if kind == 2 {
                        window = FeatureWindows.shared.show("QA Cancel Workflow") { WorkflowPanel(files: [source]) }
                        try await click("workflow.run", in: window); try await click("workflow.confirm")
                    } else {
                        let second = directory.appendingPathComponent("second.png")
                        try FileManager.default.copyItem(at: source, to: second)
                        window = FeatureWindows.shared.show("QA Cancel GIF") { AnimatedGIFPanel(files: [source, second]) }
                        try await click("Create GIF", in: window)
                    }
                    try await cancelUsingHUD()
                    if kind <= 1 {
                        let label = kind == 0 ? "Create ZIP" : "Extract all"
                        try await wait("archive retry enabled") { window.contentView.flatMap { elements($0).first { $0.label == label } }?.enabled == true }
                        try expect(window.isVisible, "cancelled archive panel remains available")
                    }
                    try expectEqual(try Data(contentsOf: source), original)
                    try expectEqual(try Data(contentsOf: archive), archiveData)
                }
            }
        }
    }
}
