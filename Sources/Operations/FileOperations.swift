import Foundation

enum FileOperations {
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

    static func extract(_ archive: URL, to destination: URL, selected: Set<String>? = nil, password: String? = nil, progress: @escaping (Double) -> Void)
        async throws
    {
        try SafeArchive.extract(archive, to: destination, selected: selected, password: password, progress: progress)
    }

    static func inspectArchive(_ archive: URL) async throws -> [ArchiveEntryInfo] { try SafeArchive.inspect(archive) }

    static func inspectArchive(_ archive: URL, password: String?) async throws -> [ArchiveEntryInfo] { try SafeArchive.inspect(archive, password: password) }

}
