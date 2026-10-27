import Darwin
import Foundation

/// Passwords stay inside libarchive, never in a subprocess argument list.
enum EncryptedZIP {
    private typealias New = @convention(c) () -> OpaquePointer?
    private typealias Action = @convention(c) (OpaquePointer?) -> Int32
    private typealias Text = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?) -> Int32
    private typealias SetName = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?) -> Void
    private typealias SetSize = @convention(c) (OpaquePointer?, Int64) -> Void
    private typealias SetMode = @convention(c) (OpaquePointer?, UInt16) -> Void
    private typealias Header = @convention(c) (OpaquePointer?, OpaquePointer?) -> Int32
    private typealias Write = @convention(c) (OpaquePointer?, UnsafeRawPointer?, Int) -> Int
    private typealias FreeEntry = @convention(c) (OpaquePointer?) -> Void
    private struct API {
        let new: New; let format: Action; let options: Text; let password: Text; let open: Text; let header: Header; let write: Write; let close: Action;
        let free: Action
        let entry: New; let name: SetName; let size: SetSize; let type: SetMode; let perm: SetMode; let freeEntry: FreeEntry
    }
    private static let api: API? = {
        guard let handle = dlopen("/usr/lib/libarchive.2.dylib", RTLD_NOW | RTLD_LOCAL) else { return nil }
        func symbol<T>(_ name: String, _: T.Type) throws -> T {
            guard let pointer = dlsym(handle, name) else { throw YuzuError.invalidInput("ZIP encryption unavailable.") }
            return unsafeBitCast(pointer, to: T.self)
        }
        do {
            return try API(
                new: symbol("archive_write_new", New.self), format: symbol("archive_write_set_format_zip", Action.self),
                options: symbol("archive_write_set_options", Text.self), password: symbol("archive_write_set_passphrase", Text.self),
                open: symbol("archive_write_open_filename", Text.self), header: symbol("archive_write_header", Header.self),
                write: symbol("archive_write_data", Write.self), close: symbol("archive_write_close", Action.self),
                free: symbol("archive_write_free", Action.self),
                entry: symbol("archive_entry_new", New.self), name: symbol("archive_entry_copy_pathname", SetName.self),
                size: symbol("archive_entry_set_size", SetSize.self), type: symbol("archive_entry_set_filetype", SetMode.self),
                perm: symbol("archive_entry_set_perm", SetMode.self), freeEntry: symbol("archive_entry_free", FreeEntry.self))
        } catch { dlclose(handle); return nil }
    }()
    static var isSupported: Bool {
        guard let api, let writer = api.new() else { return false }
        defer { _ = api.free(writer) }
        return api.format(writer) == 0 && "zip:encryption=aes256".withCString({ api.options(writer, $0) }) == 0
    }

    static func create(_ urls: [URL], to destination: URL, password: String, progress: @escaping (Double) -> Void) async throws {
        guard isSupported, let api, !password.isEmpty, let first = urls.first else {
            throw YuzuError.invalidInput("AES-256 ZIP encryption is unavailable or its password is empty.")
        }
        for source in urls where destination.resolvingSymlinksInPath().path.hasPrefix(source.resolvingSymlinksInPath().path + "/") {
            throw YuzuError.invalidInput("Save the ZIP outside every selected source folder.")
        }
        try OutputTransaction.validateDestination(source: first, destination: destination, format: .zip)
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".yuzu-encrypted-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: staging) }
        guard let writer = api.new() else { throw YuzuError.encodeFailed("ZIP writer") }
        defer { _ = api.free(writer) }
        guard api.format(writer) == 0, "zip:encryption=aes256".withCString({ api.options(writer, $0) }) == 0,
            password.withCString({ api.password(writer, $0) }) == 0,
            staging.path.withCString({ api.open(writer, $0) }) == 0
        else { throw YuzuError.encodeFailed("ZIP encryption setup") }
        var names = Set<String>()
        func add(_ source: URL, path: String) throws {
            try Task.checkCancellation()
            let path = try SafeArchive.safePath(path)
            guard names.insert(path.precomposedStringWithCanonicalMapping.lowercased()).inserted else {
                throw YuzuError.invalidInput("Conflicting ZIP entry: \(path).")
            }
            let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isSymbolicLink != true, values.isDirectory == true || values.isRegularFile == true, let entry = api.entry() else {
                throw YuzuError.unreadable(source)
            }
            defer { api.freeEntry(entry) }
            path.withCString { api.name(entry, $0) }
            api.type(entry, values.isDirectory == true ? 0o040000 : 0o100000)
            api.perm(entry, values.isDirectory == true ? 0o700 : 0o600)
            api.size(entry, values.isDirectory == true ? 0 : Int64(values.fileSize ?? 0))
            guard api.header(writer, entry) == 0 else { throw YuzuError.encodeFailed("encrypted ZIP entry") }
            if values.isDirectory == true {
                for child in try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
                    try add(child, path: path + "/" + child.lastPathComponent)
                }
            } else {
                let handle = try FileHandle(forReadingFrom: source)
                defer { try? handle.close() }
                while let data = try handle.read(upToCount: 65_536), !data.isEmpty {
                    try Task.checkCancellation()
                    guard data.withUnsafeBytes({ api.write(writer, $0.baseAddress, $0.count) }) == data.count else {
                        throw YuzuError.encodeFailed("encrypted ZIP contents")
                    }
                }
            }
        }
        for (index, source) in urls.enumerated() { try add(source, path: source.lastPathComponent); progress(Double(index + 1) / Double(urls.count + 1)) }
        guard api.close(writer) == 0 else { throw YuzuError.encodeFailed("encrypted ZIP finalization") }
        _ = try SafeArchive.inspect(staging, password: password)
        try Task.checkCancellation()
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staging.path)
        try FileManager.default.moveItem(at: staging, to: destination)
        progress(1)
    }
}
