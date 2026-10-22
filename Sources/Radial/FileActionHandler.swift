import AppKit
import Foundation

enum FileActionError: LocalizedError {
    case emptySelection
    case unavailable(String)
    case collision(String)
    case invalidDestination

    var errorDescription: String? {
        switch self {
        case .emptySelection: return "No files were selected."
        case .unavailable(let action): return "\(action) is not available on this Mac."
        case .collision(let name): return "A file or folder named \(name) already exists in the destination."
        case .invalidDestination: return "Choose a different destination folder."
        }
    }
}

@MainActor
final class FileActionHandler {
    func perform(_ action: RadialFileAction, urls: [URL], onError: @escaping (String) -> Void) {
        guard !urls.isEmpty else {
            onError(FileActionError.emptySelection.localizedDescription)
            return
        }
        let selection = FileSelection(urls: urls).urls
        guard !selection.isEmpty else {
            onError(FileActionError.emptySelection.localizedDescription)
            return
        }

        switch action {
        case .copy:
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            guard pasteboard.writeObjects(selection as [NSURL]) else {
                onError("Yuzu could not write the selection to the clipboard.")
                return
            }
            DiagnosticLog.log("copied " + String(selection.count) + " path(s) to the pasteboard")

        case .copyPath:
            let paths = selection.map(\.path).joined(separator: "\n")
            guard NSPasteboard.general.setString(paths, forType: .string) else {
                onError("Yuzu could not write the paths to the clipboard.")
                return
            }
            DiagnosticLog.log("copied " + String(selection.count) + " path(s) as text")

        case .move:
            chooseMoveDestination(for: selection, onError: onError)

        case .rename:
            chooseRename(for: selection, onError: onError)

        case .airDrop:
            guard let service = NSSharingService(named: .sendViaAirDrop) else {
                onError(FileActionError.unavailable("AirDrop").localizedDescription)
                return
            }
            service.perform(withItems: selection)

        case .terminal:
            guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
                onError(FileActionError.unavailable("Terminal").localizedDescription)
                return
            }
            NSWorkspace.shared.open(selection, withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    private func chooseMoveDestination(for urls: [URL], onError: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.title = "Move Selected Items"
        panel.prompt = "Move"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.begin { [weak self] response in
            guard response == .OK, let destination = panel.url else { return }
            self?.move(urls, to: destination, onError: onError)
        }
    }

    private func chooseRename(for urls: [URL], onError: @escaping (String) -> Void) {
        guard urls.count == 1, let source = urls.first else {
            onError("Rename supports one file or folder at a time.")
            return
        }

        let alert = NSAlert()
        alert.messageText = "Rename Item"
        alert.informativeText = source.lastPathComponent
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: source.lastPathComponent)
        field.frame.size = NSSize(width: 300, height: 24)
        alert.accessoryView = field

        let handleResponse: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.rename(source, to: field.stringValue, onError: onError)
        }
        let parentWindow = [NSApp.keyWindow, NSApp.mainWindow]
            .compactMap { $0 }
            .first { $0.isVisible }
        if let parentWindow {
            alert.beginSheetModal(for: parentWindow, completionHandler: handleResponse)
        } else {
            handleResponse(alert.runModal())
        }
    }

    private func rename(_ source: URL, to rawName: String, onError: @escaping (String) -> Void) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains(":") else {
            onError("Choose a valid file or folder name without slashes or colons.")
            return
        }
        let target = source.deletingLastPathComponent().appendingPathComponent(name)
        guard target.standardizedFileURL != source.standardizedFileURL else { return }
        guard !FileManager.default.fileExists(atPath: target.path) else {
            onError(FileActionError.collision(name).localizedDescription)
            return
        }
        do {
            try FileManager.default.moveItem(at: source, to: target)
            DiagnosticLog.log("renamed item to " + name)
        } catch {
            onError("Yuzu could not rename the item: \(error.localizedDescription)")
        }
    }

    private func move(_ urls: [URL], to destination: URL, onError: @escaping (String) -> Void) {
        let sources = urls.map(\.standardizedFileURL)
        let targetDirectory = destination.standardizedFileURL
        guard FileManager.default.fileExists(atPath: targetDirectory.path) else {
            onError(FileActionError.invalidDestination.localizedDescription)
            return
        }
        for source in sources {
            guard source != targetDirectory, !targetDirectory.path.hasPrefix(source.path + "/") else {
                onError(FileActionError.invalidDestination.localizedDescription)
                return
            }
        }

        let targets = sources.map { targetDirectory.appendingPathComponent($0.lastPathComponent) }
        if let collision = targets.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            onError(FileActionError.collision(collision.lastPathComponent).localizedDescription)
            return
        }

        Task.detached(priority: .userInitiated) {
            do {
                for (source, target) in zip(sources, targets) {
                    try FileManager.default.moveItem(at: source, to: target)
                }
                DiagnosticLog.log("moved " + String(sources.count) + " item(s)")
            } catch {
                await MainActor.run { onError("Yuzu could not complete the move: \(error.localizedDescription)") }
            }
        }
    }
}
