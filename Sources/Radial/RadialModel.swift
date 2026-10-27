import AppKit
import Foundation

enum RadialMode: String, CaseIterable, Identifiable, Hashable {
    case conversion
    case tools
    case actions
    case flow

    var id: String { rawValue }

    var title: String {
        switch self {
        case .conversion: return "Convert"
        case .tools: return "Tools"
        case .actions: return "Actions"
        case .flow: return "Tasks"
        }
    }

    var symbol: String {
        switch self {
        case .conversion: return "arrow.triangle.2.circlepath"
        case .tools: return "slider.horizontal.3"
        case .actions: return "hand.raised"
        case .flow: return "sparkles"
        }
    }

    var defaultModifier: RadialModifier {
        switch self {
        case .conversion: return .shift
        case .tools: return .command
        case .actions: return .control
        case .flow: return .option
        }
    }
}

enum RadialModifier: String, CaseIterable, Identifiable, Hashable {
    case shift
    case command
    case control
    case option

    var id: String { rawValue }

    var title: String {
        switch self {
        case .shift: return "Shift"
        case .command: return "Command"
        case .control: return "Control"
        case .option: return "Option"
        }
    }

    var symbol: String {
        switch self {
        case .shift: return "shift"
        case .command: return "command"
        case .control: return "control"
        case .option: return "option"
        }
    }

    var flags: NSEvent.ModifierFlags {
        switch self {
        case .shift: return .shift
        case .command: return .command
        case .control: return .control
        case .option: return .option
        }
    }
}

enum RadialFileAction: String, CaseIterable, Hashable {
    case copy
    case copyPath
    case move
    case rename
    case airDrop
    case terminal
    case createZIP, extractArchive, duplicate, trash, reveal, quickLook
    case inspect, openWith, newFolder, share

    var title: String {
        switch self {
        case .copy: return "Copy"
        case .copyPath: return "Copy Path"
        case .move: return "Move"
        case .rename: return "Rename"
        case .airDrop: return "AirDrop"
        case .terminal: return "Terminal"
        case .createZIP: return "Create ZIP"
        case .extractArchive: return "Extract"
        case .duplicate: return "Make a Copy"
        case .trash: return "Move to Trash"
        case .reveal: return "Reveal"
        case .quickLook: return "Quick Look"
        case .inspect: return "Inspect"
        case .openWith: return "Open With"
        case .newFolder: return "New Folder"
        case .share: return "Share"
        }
    }

    var symbol: String {
        switch self {
        case .copy: return "doc.on.doc"
        case .copyPath: return "link"
        case .move: return "folder"
        case .rename: return "pencil"
        case .airDrop: return "airplayaudio"
        case .terminal: return "terminal"
        case .createZIP: return "archivebox"
        case .extractArchive: return "tray.and.arrow.down"
        case .duplicate: return "plus.square.on.square"
        case .trash: return "trash"
        case .reveal: return "magnifyingglass"
        case .quickLook: return "eye"
        case .inspect: return "info.circle"
        case .openWith: return "app.badge"
        case .newFolder: return "folder.badge.plus"
        case .share: return "square.and.arrow.up"
        }
    }

    var detail: String {
        switch self {
        case .copy: return "Copy the selected files"
        case .copyPath: return "Copy one path per line"
        case .move: return "Choose a destination folder"
        case .rename: return "Rename the selected file or folder"
        case .airDrop: return "Share with AirDrop"
        case .terminal: return "Open in Terminal"
        case .createZIP: return "Create a ZIP containing the selection"
        case .extractArchive: return "Extract into a new folder"
        case .duplicate: return "Create copies beside the originals"
        case .trash: return "Move selected items to the Trash"
        case .reveal: return "Show the selection in Finder"
        case .quickLook: return "Preview selected items"
        case .inspect: return "Inspect file sizes, dates and permissions"
        case .openWith: return "Choose an installed application"
        case .newFolder: return "Move the selection into a new folder"
        case .share: return "Choose a macOS sharing service"
        }
    }
}

enum RadialAction: Hashable {
    case convert(FileFormat)
    case tool(ToolID)
    case file(RadialFileAction)
    case more([RadialItem])
    case task(TaskID)
    case animatedGIF
}

struct RadialItem: Identifiable, Hashable {
    let action: RadialAction
    let label: String
    let detail: String
    let symbol: String

    var id: RadialAction { action }
    var accessibilityLabel: String { label == detail ? label : label + ". " + detail }

    init(format: FileFormat) {
        action = .convert(format)
        label = format.displayName
        detail = "Convert to " + format.displayName
        symbol = format.category.symbol
    }

    init(tool: ToolID) {
        action = .tool(tool)
        label = tool.radialLabel
        detail = tool.title
        symbol = tool.symbol
    }

    init(fileAction: RadialFileAction) {
        action = .file(fileAction)
        label = fileAction.title
        detail = fileAction.detail
        symbol = fileAction.symbol.trimmingCharacters(in: .whitespaces)
    }

    init(action: RadialAction, label: String, detail: String, symbol: String) {
        self.action = action
        self.label = label
        self.detail = detail
        self.symbol = symbol
    }
}

struct FileSelection: Equatable, Hashable {
    let urls: [URL]

    init(urls: [URL]) {
        var seen = Set<URL>()
        self.urls = urls.compactMap { url in
            guard url.isFileURL else { return nil }
            let standardized = url.standardizedFileURL
            guard seen.insert(standardized).inserted else { return nil }
            return standardized
        }
    }

    var isEmpty: Bool { urls.isEmpty }
    var fileName: String? { urls.count == 1 ? urls[0].lastPathComponent : nil }
    var containsDirectory: Bool {
        urls.contains { url in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { return false }
            let isDocumentPackage =
                FileFormat.detect(url).map { [.pages, .rtfd].contains($0) } == true && (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) == true
            return !isDocumentPackage
        }
    }

    var context: String {
        guard !urls.isEmpty else { return "Waiting for files" }
        if urls.count > 1 { return String(urls.count) + " files" }
        let ext = urls[0].pathExtension.uppercased()
        return ext.isEmpty ? "FILE · 1 file" : ext + " · 1 file"
    }
}

struct RadialContent {
    let items: [RadialItem]
    let emptyMessage: String
    let emptyDetail: String
    let context: String
    let fileName: String?
}

enum RadialProvider {
    static func content(for urls: [URL], mode: RadialMode, capabilities: BackendCapabilities = RuntimeCapabilities.snapshot) -> RadialContent {
        let selection = FileSelection(urls: urls)
        guard !selection.isEmpty else {
            return RadialContent(
                items: [],
                emptyMessage: "Waiting for files",
                emptyDetail: "Keep dragging until the selection is available",
                context: selection.context,
                fileName: selection.fileName
            )
        }

        switch mode {
        case .conversion:
            let formats = selection.urls.compactMap(FileFormat.detect)
            guard formats.count == selection.urls.count, !selection.containsDirectory else {
                return RadialContent(
                    items: [], emptyMessage: "Unsupported input", emptyDetail: "Conversion needs supported files", context: selection.context,
                    fileName: selection.fileName)
            }
            var items = ConversionMatrix.targets(for: formats).filter { target in
                formats.allSatisfy { capabilities.supports(from: $0, to: target) }
            }.map { target -> RadialItem in
                if formats.allSatisfy({ $0 == .pdf }), target == .pptx {
                    return RadialItem(action: .convert(target), label: target.displayName, detail: "PDF pages as image slides", symbol: target.category.symbol)
                }
                if formats.allSatisfy({ $0 == .pdf }), target == .xlsx {
                    return RadialItem(
                        action: .convert(target), label: target.displayName, detail: "PDF text as worksheet rows, one sheet per page",
                        symbol: target.category.symbol)
                }
                return RadialItem(format: target)
            }
            if formats.count >= 2, formats.allSatisfy({ $0.category == .image }) {
                items.append(RadialItem(action: .animatedGIF, label: "Animated GIF", detail: "Combine images as animation frames", symbol: "photo.stack"))
            }
            if formats.allSatisfy({ $0 == .pdf }), let index = items.firstIndex(where: { $0.action == .convert(.svg) }) {
                items[index] = RadialItem(action: .convert(.svg), label: "SVG", detail: "PDF pages as SVG with embedded PNG", symbol: "photo")
            }
            if formats.allSatisfy({ $0 == .html }) {
                items = items.map { RadialItem(action: $0.action, label: $0.label, detail: "HTML text only · no web resources loaded", symbol: $0.symbol) }
            }
            if items.count > 8 {
                items =
                    Array(items.prefix(7)) + [
                        RadialItem(action: .more(Array(items.dropFirst(7))), label: "More", detail: "More conversion formats", symbol: "ellipsis")
                    ]
            }
            return RadialContent(
                items: items, emptyMessage: "No conversions available", emptyDetail: "No compatible backend is available. Check Settings.",
                context: selection.context,
                fileName: selection.fileName)

        case .tools:
            let formats = selection.urls.compactMap(FileFormat.detect)
            if selection.urls.count == 2, !selection.containsDirectory, formats.count != 2 {
                return RadialContent(
                    items: [RadialItem(tool: .fileComparison)], emptyMessage: "", emptyDetail: "", context: selection.context, fileName: selection.fileName)
            }
            guard formats.count == selection.urls.count, !selection.containsDirectory else {
                return RadialContent(
                    items: [], emptyMessage: "Unsupported input", emptyDetail: "Tools need supported files", context: selection.context,
                    fileName: selection.fileName)
            }
            let available = ToolID.available(for: formats).filter { capabilities.supports(tool: $0, formats: formats) }.map(RadialItem.init(tool:))
            let items =
                available.count > 8
                ? Array(available.prefix(7)) + [
                    RadialItem(action: .more(Array(available.dropFirst(7))), label: "More", detail: "More tools", symbol: "ellipsis")
                ] : available
            return RadialContent(
                items: items, emptyMessage: "No tools for this selection", emptyDetail: "Try a supported file type or selection size",
                context: selection.context, fileName: selection.fileName)

        case .actions:
            let actions = availableFileActions(for: selection).map(RadialItem.init(fileAction:))
            let items: [RadialItem]
            if actions.count > 8 {
                items =
                    Array(actions.prefix(7)) + [
                        RadialItem(action: .more(Array(actions.dropFirst(7))), label: "More", detail: "More file actions", symbol: "ellipsis")
                    ]
            } else {
                items = actions
            }
            return RadialContent(
                items: items, emptyMessage: "No actions available", emptyDetail: "The selected paths cannot be used", context: selection.context,
                fileName: selection.fileName)

        case .flow:
            let items = flowItems(for: selection)
            return RadialContent(
                items: items, emptyMessage: "No tasks available", emptyDetail: "Try a supported file or folder selection", context: selection.context,
                fileName: selection.fileName)
        }
    }

    private static func availableFileActions(for selection: FileSelection) -> [RadialFileAction] {
        var actions: [RadialFileAction] = [.copy, .copyPath, .createZIP, .quickLook, .reveal, .move]
        if selection.urls.allSatisfy(SafeArchive.supports) { actions.insert(.extractArchive, at: 3) }
        if selection.urls.count == 1 { actions.append(.rename) }
        actions += [.duplicate, .trash, .inspect]
        if !selection.containsDirectory { actions.append(.openWith) }
        if let first = selection.urls.first, selection.urls.allSatisfy({ $0.deletingLastPathComponent() == first.deletingLastPathComponent() }) {
            actions.append(.newFolder)
        }
        actions.append(.share)
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") != nil {
            actions.append(.terminal)
        }
        return actions
    }

    private static func flowItems(for selection: FileSelection) -> [RadialItem] {
        var tasks: [TaskID] = [.smartOrganize]
        if selection.urls.count >= 2 { tasks.insert(.batchRename, at: 0) }
        let formats = selection.urls.compactMap(FileFormat.detect)
        if selection.urls.count >= 2, formats.count == selection.urls.count, !selection.containsDirectory,
            RuntimeCapabilities.snapshot.supports(tool: .compress, formats: formats)
        {
            tasks.append(.batchOptimize)
        }
        tasks += [.duplicateFinder, .fileShelf]
        if formats.count == selection.urls.count, !selection.containsDirectory, formats.allSatisfy({ $0.category != .archive }) { tasks.append(.workflow) }
        return tasks.map {
            RadialItem(
                action: .task($0), label: $0.title,
                detail: $0 == .duplicateFinder ? "Find identical files by content; originals are kept" : $0.title, symbol: $0.symbol)
        }
    }
}

struct DragSessionUpdate {
    let id: UUID
    let urls: [URL]
    let mode: RadialMode?
    let point: NSPoint
    let dragConfirmed: Bool
}

struct RadialModeResolver {
    let assignments: [RadialMode: RadialModifier]
    private var lastHeldModes = Set<RadialMode>()
    private var pressedHistory: [RadialMode] = []
    private(set) var currentMode: RadialMode?
    private(set) var usingLegacyAlias = false

    init(assignments: [RadialMode: RadialModifier]) {
        self.assignments = assignments
    }

    mutating func resolve(_ flags: NSEvent.ModifierFlags) -> RadialMode? {
        let heldModes = Set(
            RadialMode.allCases.filter { mode in
                guard let modifier = assignments[mode] else { return false }
                return flags.contains(modifier.flags)
            })
        let newlyPressed = heldModes.subtracting(lastHeldModes)
        for mode in RadialMode.allCases where newlyPressed.contains(mode) {
            pressedHistory.removeAll { $0 == mode }
            pressedHistory.append(mode)
        }
        lastHeldModes = heldModes

        let toolsModifier = assignments[.tools]?.flags ?? .command
        let hasLegacyTools = flags.contains(.shift) && flags.contains(.option) && !flags.contains(toolsModifier)
        if hasLegacyTools, assignments[.conversion] == .shift {
            usingLegacyAlias = true
            currentMode = .tools
            return .tools
        }
        if usingLegacyAlias {
            usingLegacyAlias = false
            if heldModes.contains(.conversion) {
                currentMode = .conversion
                return .conversion
            }
        }

        if let mode = pressedHistory.reversed().first(where: heldModes.contains) {
            currentMode = mode
            return mode
        }
        return currentMode
    }
}
