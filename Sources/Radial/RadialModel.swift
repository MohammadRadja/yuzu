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

    var title: String {
        switch self {
        case .copy: return "Copy"
        case .copyPath: return "Copy Path"
        case .move: return "Move"
        case .rename: return "Rename"
        case .airDrop: return "AirDrop"
        case .terminal: return "Terminal"
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
        }
    }
}

enum RadialAction: Hashable {
    case convert(FileFormat)
    case tool(ToolID)
    case file(RadialFileAction)
}

struct RadialItem: Identifiable, Hashable {
    let action: RadialAction
    let label: String
    let detail: String
    let symbol: String

    var id: RadialAction { action }

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
    static func content(for urls: [URL], mode: RadialMode) -> RadialContent {
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
            let items = ConversionMatrix.targets(for: formats).map { target -> RadialItem in
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
            return RadialContent(
                items: items, emptyMessage: "No conversions available", emptyDetail: "This selection has no compatible targets", context: selection.context,
                fileName: selection.fileName)

        case .tools:
            let formats = selection.urls.compactMap(FileFormat.detect)
            guard formats.count == selection.urls.count, !selection.containsDirectory else {
                return RadialContent(
                    items: [], emptyMessage: "Unsupported input", emptyDetail: "Tools need supported files", context: selection.context,
                    fileName: selection.fileName)
            }
            let items = ToolID.available(for: formats).map(RadialItem.init(tool:))
            return RadialContent(
                items: items, emptyMessage: "No tools for this selection", emptyDetail: "Try a supported file type or selection size",
                context: selection.context, fileName: selection.fileName)

        case .actions:
            let items = availableFileActions(for: selection).map(RadialItem.init(fileAction:))
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
        var actions: [RadialFileAction] = [.copy, .copyPath, .move]
        if selection.urls.count == 1 { actions.append(.rename) }
        if NSSharingService(named: .sendViaAirDrop) != nil { actions.append(.airDrop) }
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") != nil {
            actions.append(.terminal)
        }
        return actions
    }

    private static func flowItems(for selection: FileSelection) -> [RadialItem] {
        var items: [RadialItem] = []
        let formats = selection.urls.compactMap(FileFormat.detect)
        if formats.count == selection.urls.count, !selection.containsDirectory, ToolID.compress.applies(to: formats) {
            items.append(
                RadialItem(
                    action: .tool(.compress),
                    label: "OPTIMIZE",
                    detail: "Open Yuzu's compression controls",
                    symbol: ToolID.compress.symbol
                ))
        }
        items.append(contentsOf: [
            RadialItem(
                action: .file(.move),
                label: "ORGANIZE",
                detail: "Choose a destination folder",
                symbol: RadialFileAction.move.symbol
            )
        ])
        if selection.urls.count == 1 {
            items.append(
                RadialItem(
                    action: .file(.rename),
                    label: "RENAME",
                    detail: "Rename the selected file or folder",
                    symbol: RadialFileAction.rename.symbol
                ))
        }
        if NSSharingService(named: .sendViaAirDrop) != nil {
            items.append(
                RadialItem(
                    action: .file(.airDrop),
                    label: "SHARE",
                    detail: "Share with AirDrop",
                    symbol: RadialFileAction.airDrop.symbol
                ))
        }
        return items
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
