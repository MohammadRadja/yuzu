import AppKit

/// Explicit, process-local diagnostics. Normal launches keep production behavior.
enum ValidationRuntime {
    @MainActor static var fileSelections: [[URL]] = []
    @MainActor static var revealedSelections: [[URL]] = []

    @MainActor
    static func reveal(_ files: [URL]) {
        if ownedGUI { revealedSelections.append(files) } else { NSWorkspace.shared.activateFileViewerSelecting(files) }
    }
    static var ownedGUI: Bool { ProcessInfo.processInfo.environment["YUZU_OWNED_GUI_TESTS"] == "1" }
    static var nativeOnly: Bool { ProcessInfo.processInfo.environment["YUZU_NATIVE_ONLY_TESTS"] == "1" }

    static var isolatedDefaults: UserDefaults? {
        guard ownedGUI || nativeOnly,
            let name = ProcessInfo.processInfo.environment["YUZU_QA_DEFAULTS_SUITE"], name.hasPrefix("YuzuQA-")
        else { return nil }
        return UserDefaults(suiteName: name)
    }

    @MainActor
    static func present(_ window: NSWindow, activate: Bool = false) {
        if ownedGUI {
            window.orderBack(nil)
        } else {
            if activate { NSApp.activate(ignoringOtherApps: true) }
            window.makeKeyAndOrderFront(nil)
        }
    }
}
