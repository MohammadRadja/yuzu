import Darwin
import Foundation

struct ArchiveEntryInfo: Identifiable, Hashable {
    let path: String
    let size: Int64
    let isDirectory: Bool
    var id: String { path }
}

struct ArchiveLimits {
    var entries = 10_000
    var entryBytes: Int64 = 512 * 1_024 * 1_024
    var totalBytes: Int64 = 2 * 1_024 * 1_024 * 1_024
    var expansionRatio: Int64 = 1_000
    var seconds: Double = 120
}

/// Uses the OS-maintained libarchive reader, never its extract-to-disk API.
/// All paths and byte budgets are checked before Foundation writes each chunk.
enum SafeArchive {
    private typealias New = @convention(c) () -> OpaquePointer?
    private typealias Configure = @convention(c) (OpaquePointer?) -> Int32
    private typealias Open = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, Int) -> Int32
    private typealias Next = @convention(c) (OpaquePointer?, UnsafeMutablePointer<OpaquePointer?>?) -> Int32
    private typealias Read = @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?, Int) -> Int
    private typealias StringValue = @convention(c) (OpaquePointer?) -> UnsafePointer<CChar>?
    private typealias Size = @convention(c) (OpaquePointer?) -> Int64
    private typealias FileType = @convention(c) (OpaquePointer?) -> UInt16
    private typealias Passphrase = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?) -> Int32
    private struct Library {
        let handle: UnsafeMutableRawPointer
        let new: New
        let filters: Configure
        let formats: Configure
        let raw: Configure
        let free: Configure
        let open: Open
        let next: Next
        let read: Read
        let path: StringValue
        let size: Size
        let fileType: FileType
        let symlink: StringValue
        let hardlink: StringValue
        let encrypted: Configure
        let error: StringValue
        let passphrase: Passphrase
    }
    private static let library: Library? = {
        guard let handle = dlopen("/usr/lib/libarchive.2.dylib", RTLD_NOW | RTLD_LOCAL) else { return nil }
        func symbol<T>(_ name: String, _: T.Type) throws -> T {
            guard let pointer = dlsym(handle, name) else { throw YuzuError.invalidInput("Archive backend unavailable.") }
            return unsafeBitCast(pointer, to: T.self)
        }
        do {
            return try Library(
                handle: handle,
                new: symbol("archive_read_new", New.self), filters: symbol("archive_read_support_filter_all", Configure.self),
                formats: symbol("archive_read_support_format_all", Configure.self), raw: symbol("archive_read_support_format_raw", Configure.self),
                free: symbol("archive_read_free", Configure.self), open: symbol("archive_read_open_filename", Open.self),
                next: symbol("archive_read_next_header", Next.self), read: symbol("archive_read_data", Read.self),
                path: symbol("archive_entry_pathname_utf8", StringValue.self), size: symbol("archive_entry_size", Size.self),
                fileType: symbol("archive_entry_filetype", FileType.self), symlink: symbol("archive_entry_symlink", StringValue.self),
                hardlink: symbol("archive_entry_hardlink", StringValue.self), encrypted: symbol("archive_entry_is_encrypted", Configure.self),
                error: symbol("archive_error_string", StringValue.self), passphrase: symbol("archive_read_add_passphrase", Passphrase.self))
        } catch { dlclose(handle); return nil }
    }()

    static var isAvailable: Bool { library != nil }
    static func supports(_ url: URL) -> Bool {
        guard let library else { return false }
        let symbol: String
        switch url.pathExtension.lowercased() {
        case "zip": symbol = "archive_read_support_format_zip"
        case "rar": symbol = "archive_read_support_format_rar"
        case "7z": symbol = "archive_read_support_format_7zip"
        case "tar", "tgz": symbol = "archive_read_support_format_tar"
        case "gz": symbol = "archive_read_support_filter_gzip"
        default: return false
        }
        return dlsym(library.handle, symbol) != nil
    }

    static func safePath(_ raw: String) throws -> String {
        guard !raw.hasPrefix("/"), !raw.contains("\\"), !raw.contains(":"), !raw.contains("\0"), raw.utf8.count <= 4096 else {
            throw YuzuError.invalidInput("The archive contains an unsafe path.")
        }
        var components = raw.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        while components.first == "." { components.removeFirst() }
        if components.last == "" { components.removeLast() }
        guard !components.isEmpty, components.count <= 64,
            components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255 })
        else { throw YuzuError.invalidInput("The archive contains an unsafe or excessively deep path.") }
        return components.joined(separator: "/")
    }

    static func inspect(_ archive: URL, password: String? = nil, limits: ArchiveLimits = ArchiveLimits()) throws -> [ArchiveEntryInfo] {
        try scan(archive, into: nil, selected: nil, password: password, limits: limits, progress: { _ in })
    }

    static func extract(
        _ archive: URL, to destination: URL, selected: Set<String>? = nil,
        password: String? = nil, limits: ArchiveLimits = ArchiveLimits(), progress: @escaping (Double) -> Void
    ) throws {
        guard supports(archive), destination.isFileURL,
            !FileManager.default.fileExists(atPath: destination.path),
            (try? destination.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true
        else { throw YuzuError.invalidInput("Choose a new extraction folder and a supported archive.") }
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".yuzu-extract-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: staging) }
        let entries = try scan(archive, into: staging, selected: selected, password: password, limits: limits, progress: progress)
        if let selected, selected.isEmpty || !selected.isSubset(of: Set(entries.map(\.path))) {
            throw YuzuError.invalidInput("The selected archive entries are no longer available.")
        }
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: staging, to: destination)
        progress(1)
    }

    private static func scan(
        _ archive: URL, into directory: URL?, selected: Set<String>?, password: String?, limits: ArchiveLimits,
        progress: (Double) -> Void
    ) throws -> [ArchiveEntryInfo] {
        try Task.checkCancellation()
        guard archive.isFileURL, let library, let reader = library.new() else { throw YuzuError.unreadable(archive) }
        defer { _ = library.free(reader) }
        let values = try archive.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw YuzuError.unreadable(archive) }
        func failure() -> YuzuError {
            let detail = library.error(reader).map { String(cString: $0) } ?? "Damaged or unsupported archive."
            return .invalidInput("Could not read the archive: \(detail). Encrypted archives require a supported password-capable backend.")
        }
        guard library.filters(reader) == 0, library.formats(reader) == 0 else { throw failure() }
        if let password, !password.isEmpty {
            guard password.withCString({ library.passphrase(reader, $0) }) == 0 else { throw failure() }
        }
        let plainGzip = archive.pathExtension.lowercased() == "gz" && !archive.lastPathComponent.lowercased().hasSuffix(".tar.gz")
        if plainGzip {
            let handle = try FileHandle(forReadingFrom: archive)
            defer { try? handle.close() }
            guard try handle.read(upToCount: 2) == Data([0x1f, 0x8b]), library.raw(reader) == 0 else { throw failure() }
        }
        guard archive.path.withCString({ library.open(reader, $0, 65_536) }) == 0 else { throw failure() }
        let started = ProcessInfo.processInfo.systemUptime
        let compressedSize = max(1, Int64(values.fileSize ?? 1))
        let ratioLimit = compressedSize.multipliedReportingOverflow(by: limits.expansionRatio)
        let byteLimit = min(limits.totalBytes, max(1_048_576, ratioLimit.overflow ? Int64.max : ratioLimit.partialValue))
        var total: Int64 = 0
        var entries: [ArchiveEntryInfo] = []
        var seen = Set<String>()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime - started < limits.seconds else {
                throw YuzuError.invalidInput("Archive processing exceeded its time limit.")
            }
            var entry: OpaquePointer?
            let status = library.next(reader, &entry)
            if status == 1 { break }
            guard status == 0, let entry, let raw = library.path(entry) else { throw failure() }
            guard entries.count < limits.entries else { throw YuzuError.invalidInput("The archive contains too many entries.") }
            guard library.encrypted(entry) == 0 || password?.isEmpty == false else {
                throw YuzuError.invalidInput("This archive is encrypted. Open Advanced in Extract and supply its password, or use its original application.")
            }
            let kind = Int(library.fileType(entry))
            guard library.symlink(entry) == nil, library.hardlink(entry) == nil, kind == 0o100000 || kind == 0o040000 else {
                throw YuzuError.invalidInput("Archives containing links or special files cannot be extracted by Yuzu.")
            }
            var rawPath = String(cString: raw)
            if kind == 0o040000 && [".", "./"].contains(rawPath) { continue }
            if plainGzip && rawPath == "data" { rawPath = archive.deletingPathExtension().lastPathComponent }
            let path = try safePath(rawPath)
            let canonical = path.precomposedStringWithCanonicalMapping.lowercased()
            guard seen.insert(canonical).inserted else { throw YuzuError.invalidInput("The archive contains conflicting entry names: \(path).") }
            let size = library.size(entry)
            guard size >= 0, size <= limits.entryBytes, size <= byteLimit - total else {
                throw YuzuError.invalidInput("The archive exceeds the extraction size limit.")
            }
            let info = ArchiveEntryInfo(path: path, size: size, isDirectory: kind == 0o040000)
            entries.append(info)
            let shouldWrite = selected == nil || selected?.contains(path) == true || selected?.contains(where: { path.hasPrefix($0 + "/") }) == true
            let output = shouldWrite ? directory?.appendingPathComponent(path) : nil
            var handle: FileHandle?
            if let output {
                if info.isDirectory {
                    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                } else {
                    try FileManager.default.createDirectory(
                        at: output.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    guard !FileManager.default.fileExists(atPath: output.path),
                        FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600])
                    else { throw YuzuError.invalidInput("Conflicting archive entries: \(path).") }
                    handle = try FileHandle(forWritingTo: output)
                }
            }
            defer { try? handle?.close() }
            var actual: Int64 = 0
            while true {
                try Task.checkCancellation()
                guard ProcessInfo.processInfo.systemUptime - started < limits.seconds else {
                    throw YuzuError.invalidInput("Archive processing exceeded its time limit.")
                }
                let count = buffer.withUnsafeMutableBytes { library.read(reader, $0.baseAddress, $0.count) }
                guard count >= 0 else { throw failure() }
                if count == 0 { break }
                actual += Int64(count)
                total += Int64(count)
                guard actual <= limits.entryBytes, total <= byteLimit else {
                    throw YuzuError.invalidInput("The archive exceeds the extraction size or expansion limit.")
                }
                if let handle { try handle.write(contentsOf: Data(buffer.prefix(count))) }
                progress(min(0.95, Double(total) / Double(max(byteLimit, 1))))
            }
            if !plainGzip && !info.isDirectory && actual != size { throw failure() }
        }
        return entries
    }
}
