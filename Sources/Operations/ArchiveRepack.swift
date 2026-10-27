import Foundation

enum ArchiveRepack {
    static func export(
        _ archive: URL, selected: Set<String>?, currentPassword: String?, newPassword: String?, to destination: URL, progress: @escaping (Double) -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("yuzu-repack-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let contents = directory.appendingPathComponent("contents")
        try await FileOperations.extract(archive, to: contents, selected: selected, password: currentPassword) { progress($0 * 0.5) }
        let files = try FileManager.default.contentsOfDirectory(at: contents, includingPropertiesForKeys: nil)
        guard !files.isEmpty else { throw YuzuError.invalidInput("Select at least one archive entry to export.") }
        if let newPassword {
            try await EncryptedZIP.create(files, to: destination, password: newPassword) { progress(0.5 + $0 * 0.5) }
        } else {
            try await FileOperations.createZIP(files, to: destination) { progress(0.5 + $0 * 0.5) }
        }
    }
}
