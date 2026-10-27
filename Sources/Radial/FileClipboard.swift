import AppKit

@MainActor
enum FileClipboard {
    static func write(_ urls: [URL], pathsOnly: Bool, to pasteboard: NSPasteboard = .general) throws {
        let selection = FileSelection(urls: urls).urls
        guard !selection.isEmpty, selection.count == urls.count,
            selection.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) })
        else { throw YuzuError.invalidInput("The selected files are no longer available. Select them again.") }
        // Clear all old types: otherwise Finder can paste a previous file even
        // after Copy Path replaced only its plain-text representation.
        pasteboard.clearContents()
        let written: Bool
        if pathsOnly {
            written = pasteboard.setString(selection.map(\.path).joined(separator: "\n"), forType: .string)
        } else {
            // NSURL publishes public.file-url per item, the native Finder contract.
            written = pasteboard.writeObjects(selection as [NSURL])
        }
        guard written else { throw YuzuError.invalidInput("Yuzu could not write the selection to the clipboard. Try Copy again.") }
    }
}
