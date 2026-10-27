import Darwin
import Foundation

enum FileOperations {
    static func rename(_ source: URL, to rawName: String) throws -> URL {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard source.isFileURL, FileManager.default.fileExists(atPath: source.path),
            !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains(":"),
            !name.contains("\0"), name.utf8.count <= 255
        else { throw YuzuError.invalidInput("Choose an existing local item and a valid name without slashes or colons.") }
        let target = source.deletingLastPathComponent().appendingPathComponent(name)
        guard target.standardizedFileURL != source.standardizedFileURL else { return source }
        guard !FileManager.default.fileExists(atPath: target.path),
            (try? target.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true
        else { throw FileActionError.collision(name) }
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: source, to: target)
        return target
    }

    static func copyTree(_ source: URL, to destination: URL) throws {
        try Task.checkCancellation()
        _ = try SafeArchive.safePath(source.lastPathComponent)
        let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true else { throw YuzuError.invalidInput("Links cannot be copied into a ZIP. Select the original files instead.") }
        if values.isDirectory == true {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            for child in try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
                try copyTree(child, to: destination.appendingPathComponent(child.lastPathComponent))
            }
        } else {
            guard values.isRegularFile == true else { throw YuzuError.unreadable(source) }
            let input = try FileHandle(forReadingFrom: source)
            defer { try? input.close() }
            guard FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw YuzuError.encodeFailed(destination.lastPathComponent)
            }
            let output = try FileHandle(forWritingTo: destination)
            defer { try? output.close() }
            while let data = try input.read(upToCount: 1_048_576), !data.isEmpty {
                try Task.checkCancellation()
                try output.write(contentsOf: data)
            }
        }
    }

    static func createZIP(_ urls: [URL], to destination: URL, progress: @escaping (Double) -> Void) async throws {
        let selection = FileSelection(urls: urls).urls
        guard !selection.isEmpty else { throw YuzuError.invalidInput("Select at least one file or folder.") }
        let names = selection.map { $0.lastPathComponent.precomposedStringWithCanonicalMapping.lowercased() }
        guard Set(names).count == names.count else { throw YuzuError.invalidInput("Selected items have the same name. Rename one before creating a ZIP.") }
        for source in selection {
            guard !destination.resolvingSymlinksInPath().path.hasPrefix(source.resolvingSymlinksInPath().path + "/") else {
                throw YuzuError.invalidInput("Save the ZIP outside the selected folder.")
            }
        }
        guard let first = selection.first else { throw YuzuError.invalidInput("No files selected.") }
        try await OutputTransaction.write(source: first, destination: destination, format: .zip) { staged in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("yuzu-zip-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: directory) }
            for (index, source) in selection.enumerated() {
                try copyTree(source, to: directory.appendingPathComponent(source.lastPathComponent))
                progress(0.6 * Double(index + 1) / Double(selection.count))
            }
            try Task.checkCancellation()
            try await ZipTool.zip(directory: directory, to: staged)
            progress(0.9)
        }
        progress(1)
    }

    static func duplicate(_ source: URL, to destination: URL) async throws {
        try Task.checkCancellation()
        guard source.isFileURL, destination.isFileURL, !FileManager.default.fileExists(atPath: destination.path),
            !destination.resolvingSymlinksInPath().path.hasPrefix(source.resolvingSymlinksInPath().path + "/")
        else { throw YuzuError.invalidInput("Choose a new copy name outside the source folder.") }
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".yuzu-copy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.copyItem(at: source, to: staging)
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: staging, to: destination)
    }

    static func extract(_ archive: URL, to destination: URL, selected: Set<String>? = nil, password: String? = nil, progress: @escaping (Double) -> Void)
        async throws
    {
        try SafeArchive.extract(archive, to: destination, selected: selected, password: password, progress: progress)
    }

    static func inspectArchive(_ archive: URL) async throws -> [ArchiveEntryInfo] { try SafeArchive.inspect(archive) }

    static func inspectArchive(_ archive: URL, password: String?) async throws -> [ArchiveEntryInfo] { try SafeArchive.inspect(archive, password: password) }

    static func newFolder(_ urls: [URL], name: String) async throws -> URL {
        guard let first = urls.first, !name.isEmpty, name != ".", name != "..", name.utf8.count <= 255,
            !name.contains("/"), !name.contains(":"), !name.contains("\0"),
            urls.allSatisfy({ $0.deletingLastPathComponent().standardizedFileURL == first.deletingLastPathComponent().standardizedFileURL })
        else { throw YuzuError.invalidInput("Choose a valid folder name and items from the same parent folder.") }
        let output = first.deletingLastPathComponent().appendingPathComponent(name)
        guard output.path.withCString({ mkdir($0, 0o700) }) == 0 else {
            throw YuzuError.invalidInput("The new folder already exists or cannot be created. Choose another name.")
        }
        do { _ = try move(urls, to: output); return output } catch {
            if (try? FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty) == true { try? FileManager.default.removeItem(at: output) }
            throw error
        }
    }

    static func move(_ urls: [URL], to directory: URL) throws -> [URL] {
        let sources = FileSelection(urls: urls).urls
        let fm = FileManager.default
        guard !sources.isEmpty, directory.isFileURL, (try directory.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true else {
            throw YuzuError.invalidInput("Choose an existing destination folder.")
        }
        let resolvedDirectory = directory.resolvingSymlinksInPath().standardizedFileURL
        var targets: [URL] = []
        var names = Set<String>()
        for source in sources {
            let resolved = source.resolvingSymlinksInPath().standardizedFileURL
            guard resolvedDirectory != resolved, !resolvedDirectory.path.hasPrefix(resolved.path + "/") else { throw FileActionError.invalidDestination }
            let target = directory.appendingPathComponent(source.lastPathComponent)
            guard names.insert(target.lastPathComponent.precomposedStringWithCanonicalMapping.lowercased()).inserted,
                !fm.fileExists(atPath: target.path)
            else { throw FileActionError.collision(target.lastPathComponent) }
            targets.append(target)
        }
        var moved: [(URL, URL)] = []
        do {
            for (source, target) in zip(sources, targets) {
                try Task.checkCancellation()
                try fm.moveItem(at: source, to: target)
                moved.append((source, target))
            }
        } catch {
            var rollbackFailures: [String] = []
            for (source, target) in moved.reversed() {
                do { try fm.moveItem(at: target, to: source) } catch {
                    rollbackFailures.append("\(target.path) → \(source.path): \(error.localizedDescription)")
                }
            }
            if !rollbackFailures.isEmpty {
                throw YuzuError.invalidInput("Move stopped. Some items could not be restored:\n" + rollbackFailures.joined(separator: "\n"))
            }
            throw error
        }
        return targets
    }
}
