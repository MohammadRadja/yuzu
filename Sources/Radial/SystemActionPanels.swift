import SwiftUI

struct FileInspection {
    let url: URL
    let size: Int64
    let type: FileAttributeType
    let created: Date?
    let modified: Date?
    let permissions: Int

    static func read(_ url: URL) throws -> FileInspection {
        guard url.isFileURL else { throw YuzuError.unreadable(url) }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let type = attributes[.type] as? FileAttributeType else { throw YuzuError.unreadable(url) }
        return FileInspection(
            url: url, size: (attributes[.size] as? NSNumber)?.int64Value ?? 0, type: type,
            created: attributes[.creationDate] as? Date, modified: attributes[.modificationDate] as? Date,
            permissions: (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0)
    }
}

@MainActor
enum OpenWithService {
    static func applications(for files: [URL]) throws -> [URL] {
        let selection = FileSelection(urls: files).urls
        guard !selection.isEmpty, selection.count == files.count,
            selection.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) })
        else { throw YuzuError.invalidInput("Some selected files are no longer available. Select them again.") }
        guard let first = selection.first else { return [] }
        return NSWorkspace.shared.urlsForApplications(toOpen: first).filter { app in
            selection.dropFirst().allSatisfy { NSWorkspace.shared.urlsForApplications(toOpen: $0).contains(app) }
        }
    }

    @discardableResult
    static func open(_ files: [URL], with application: URL) async throws -> NSRunningApplication {
        guard try applications(for: files).contains(application) else {
            throw YuzuError.invalidInput("This application is not registered to open every selected file.")
        }
        let configuration = NSWorkspace.OpenConfiguration()
        if ValidationRuntime.ownedGUI {
            configuration.activates = false
            configuration.createsNewApplicationInstance = true
            configuration.promptsUserIfNeeded = false
        }
        return try await withCheckedThrowingContinuation { continuation in
            NSWorkspace.shared.open(files, withApplicationAt: application, configuration: configuration) { app, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let app {
                    continuation.resume(returning: app)
                } else {
                    continuation.resume(throwing: YuzuError.invalidInput("The selected application could not be opened."))
                }
            }
        }
    }
}

struct NativeShareButton: NSViewRepresentable {
    let files: [URL]
    final class Coordinator: NSObject {
        var files: [URL]
        var picker: NSSharingServicePicker?
        init(_ files: [URL]) { self.files = files }
        @objc func share(_ sender: NSButton) {
            picker = NSSharingServicePicker(items: files)
            picker?.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(files) }
    func makeNSView(context: Context) -> NSButton {
        NSButton(title: "Choose sharing service…", target: context.coordinator, action: #selector(Coordinator.share(_:)))
    }
    func updateNSView(_ view: NSButton, context: Context) { context.coordinator.files = files }
}

struct FileInspectView: View {
    let files: [URL]
    var body: some View {
        List(files, id: \.self) { file in
            VStack(alignment: .leading, spacing: 8) {
                Text(file.lastPathComponent).font(.headline)
                Text(file.path).textSelection(.enabled)
                switch Result(catching: { try FileInspection.read(file) }) {
                case .success(let info):
                    Text("Size: \(FileSizeFormatter.string(info.size))")
                    Text("Type: \(info.type.rawValue)")
                    if let date = info.created { Text("Created: \(date.formatted())") }
                    if let date = info.modified { Text("Modified: \(date.formatted())") }
                    Text("Permissions: \(String(info.permissions, radix: 8))")
                case .failure(let error): Text(error.localizedDescription).foregroundStyle(.red)
                }
            }.padding(.vertical, 12)
        }.padding(12)
    }
}

@MainActor
struct OpenWithView: View {
    let files: [URL]
    @State private var error: String?
    private var applications: [URL] { (try? OpenWithService.applications(for: files)) ?? [] }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            FormHint("Applications registered to open every selected file:")
            List(applications, id: \.self) { app in
                Button(FileManager.default.displayName(atPath: app.path)) {
                    Task { do { try await OpenWithService.open(files, with: app) } catch { self.error = error.localizedDescription } }
                }
                .accessibilityIdentifier("openWith." + app.lastPathComponent)
            }
            if applications.isEmpty { Text("No installed application is registered for this selection.") }
            if let error { Text(error).foregroundStyle(.red) }
        }.padding(24)
    }
}
