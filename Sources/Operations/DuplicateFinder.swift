import CryptoKit
import Foundation

enum FileHash {
    static func sha256(_ url: URL) throws -> String {
        let before = try url.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey, .fileResourceIdentifierKey,
        ])
        guard before.isRegularFile == true, before.isSymbolicLink != true else { throw YuzuError.unreadable(url) }
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var hash = SHA256()
        while let data = try input.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation()
            hash.update(data: data)
        }
        let after = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .fileResourceIdentifierKey])
        guard before.fileSize == after.fileSize, before.contentModificationDate == after.contentModificationDate,
            (before.fileResourceIdentifier as? NSObject)?.isEqual(after.fileResourceIdentifier) == true
        else { throw YuzuError.invalidInput("\(url.lastPathComponent) changed while it was being read. Try again.") }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

struct DuplicateGroup: Identifiable {
    let hash: String
    let size: Int64
    let urls: [URL]
    var id: String { hash }
}

enum DuplicateFinder {
    static func find(_ selection: [URL], progress: @escaping (Double) -> Void) async throws -> [DuplicateGroup] {
        var files = Set<URL>()
        func add(_ url: URL) throws {
            try Task.checkCancellation()
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isRegularFile == true && values.isSymbolicLink != true { files.insert(url.standardizedFileURL) }
            guard files.count <= 100_000 else { throw YuzuError.invalidInput("Select fewer than 100,000 files per duplicate scan.") }
        }
        for url in FileSelection(urls: selection).urls {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true { continue }
            if values.isDirectory == true {
                var enumerationError: Error?
                guard
                    let enumerator = FileManager.default.enumerator(
                        at: url, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                        errorHandler: { _, error in
                            enumerationError = error; return false
                        })
                else { throw YuzuError.unreadable(url) }
                while let file = enumerator.nextObject() as? URL { try add(file) }
                if let enumerationError { throw enumerationError }
            } else {
                try add(url)
            }
        }
        var sizes: [Int64: [URL]] = [:]
        for file in files { sizes[FileSizeFormatter.size(of: file), default: []].append(file) }
        let candidates = sizes.values.filter { $0.count > 1 }.flatMap { $0 }.sorted { $0.path < $1.path }
        var groups: [String: [URL]] = [:]
        for (index, file) in candidates.enumerated() {
            let key = try FileHash.sha256(file)
            groups[key, default: []].append(file)
            progress(Double(index + 1) / Double(candidates.count))
        }
        progress(1)
        return groups.compactMap { hash, urls in
            urls.count > 1 ? DuplicateGroup(hash: hash, size: FileSizeFormatter.size(of: urls[0]), urls: urls) : nil
        }.sorted { $0.urls[0].path < $1.urls[0].path }
    }
}
