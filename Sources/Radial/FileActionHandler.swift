import AppKit
import Foundation
import SwiftUI

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
        case .inspect:
            FeatureWindows.shared.show("Inspect Selection", size: NSSize(width: 640, height: 480)) { FileInspectView(files: selection) }
        case .openWith:
            FeatureWindows.shared.show("Open With", size: NSSize(width: 520, height: 440)) { OpenWithView(files: selection) }
        case .share:
            FeatureWindows.shared.show("Share Selection", size: NSSize(width: 520, height: 360)) {
                VStack(spacing: 24) {
                    Text("Share \(selection.count) item(s)").font(.headline)
                    NativeShareButton(files: selection)
                }.padding(24)
            }
        case .newFolder:
            chooseNewFolder(for: selection, onError: onError)
        case .createZIP, .extractArchive:
            FeatureWindows.shared.show(action == .createZIP ? "Create ZIP" : "Extract Archive", size: NSSize(width: 720, height: 560)) {
                ArchiveActionView(files: selection, creating: action == .createZIP)
            }

        case .duplicate:
            for source in selection {
                let directory = source.deletingLastPathComponent()
                let isFolder = (try? source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                let output =
                    isFolder || source.pathExtension.isEmpty
                    ? ConversionMatrix.uniqueDirectory(directory: directory, name: source.lastPathComponent + " copy")
                    : ConversionMatrix.uniqueURL(
                        directory: directory, baseName: source.deletingPathExtension().lastPathComponent, suffix: "copy", ext: source.pathExtension)
                JobRunner.shared.run(title: "Making a copy", detail: source.lastPathComponent, symbol: action.symbol) { progress in
                    try await FileOperations.duplicate(source, to: output)
                    progress(1)
                    return [output]
                }
            }

        case .trash:
            let alert = NSAlert()
            alert.messageText = "Move \(selection.count) item(s) to the Trash?"
            alert.informativeText = "You can restore them from the Trash in Finder."
            alert.addButton(withTitle: "Move to Trash")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            for source in selection {
                JobRunner.shared.run(title: "Moving to Trash", detail: source.lastPathComponent, symbol: action.symbol) { progress in
                    try Task.checkCancellation()
                    try FileManager.default.trashItem(at: source, resultingItemURL: nil)
                    progress(1)
                    return []
                }
            }

        case .reveal:
            NSWorkspace.shared.activateFileViewerSelecting(selection)

        case .quickLook:
            FilePreview.shared.show(selection)

        case .copy, .copyPath:
            do { try FileClipboard.write(selection, pathsOnly: action == .copyPath) } catch { onError(error.localizedDescription) }

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
        NativeFilePicker.choose(title: "Move Selected Items", directories: true, showHiddenFiles: true, prompt: "Move") { [weak self] chosen in
            guard let destination = chosen.first else { return }
            self?.move(urls, to: destination, onError: onError)
        }
    }

    private func chooseNewFolder(for urls: [URL], onError: @escaping (String) -> Void) {
        let alert = NSAlert()
        alert.messageText = "New Folder with Selection"
        alert.informativeText = "Move \(urls.count) item(s) into a new folder beside the originals."
        alert.addButton(withTitle: "Create and Move")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: "New Folder with Items")
        field.frame.size = NSSize(width: 320, height: 24)
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        JobRunner.shared.run(title: "Creating folder", detail: "\(urls.count) items", symbol: "folder.badge.plus") { progress in
            let output = try await FileOperations.newFolder(urls, name: name)
            progress(1)
            return [output]
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
        do {
            let target = try FileOperations.rename(source, to: rawName)
            DiagnosticLog.log("renamed item to " + target.lastPathComponent)
        } catch {
            onError("Yuzu could not rename the item: \(error.localizedDescription)")
        }
    }

    private func move(_ urls: [URL], to destination: URL, onError: @escaping (String) -> Void) {
        JobRunner.shared.run(title: "Moving items", detail: "\(urls.count) items", symbol: "folder") { progress in
            let outputs = try FileOperations.move(urls, to: destination)
            progress(1)
            return outputs
        }
    }
}
