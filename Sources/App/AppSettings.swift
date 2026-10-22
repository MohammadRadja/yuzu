import AppKit
import Combine
import Foundation
import ServiceManagement

enum CompressionPreset: String, CaseIterable, Identifiable {
    case balanced
    case strong

    var id: String { rawValue }

    var title: String { rawValue.capitalized }

    var imageQuality: Double { self == .balanced ? 0.72 : 0.5 }
    var videoScale: Double { self == .balanced ? 1.0 : 0.75 }
    var videoBitrateFactor: Double { self == .balanced ? 0.6 : 0.35 }
    var audioBitrate: Int { self == .balanced ? 128_000 : 64_000 }
}

enum OutputLocation: String, CaseIterable, Identifiable {
    case besideOriginal
    case downloads
    case desktop

    var id: String { rawValue }

    var title: String {
        switch self {
        case .besideOriginal: return "Next to the original"
        case .downloads: return "Downloads"
        case .desktop: return "Desktop"
        }
    }

    func directory(for source: URL) -> URL {
        switch self {
        case .besideOriginal: return source.deletingLastPathComponent()
        case .downloads: return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        case .desktop: return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        }
    }
}

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var appearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

enum ProgressStyle: String, CaseIterable, Identifiable {
    case card
    case pill

    var id: String { rawValue }

    var title: String {
        switch self {
        case .card: return "Card"
        case .pill: return "Notch pill"
        }
    }
}

final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults: UserDefaults

    @Published var radialSoundEnabled: Bool {
        didSet { defaults.set(radialSoundEnabled, forKey: "radialSoundEnabled") }
    }

    @Published var compressionPreset: CompressionPreset {
        didSet { defaults.set(compressionPreset.rawValue, forKey: "compressionPreset") }
    }

    @Published var compressionResizeLongEdge: Int {
        didSet { defaults.set(compressionResizeLongEdge, forKey: "compressionResizeLongEdge") }
    }

    @Published var outputLocation: OutputLocation {
        didSet { defaults.set(outputLocation.rawValue, forKey: "outputLocation") }
    }

    @Published var revealInFinder: Bool {
        didSet { defaults.set(revealInFinder, forKey: "revealInFinder") }
    }

    @Published var progressStyle: ProgressStyle {
        didSet { defaults.set(progressStyle.rawValue, forKey: "progressStyle") }
    }

    @Published var ffmpegPath: String {
        didSet { defaults.set(ffmpegPath, forKey: "ffmpegPath") }
    }

    @Published var launchAtLogin: Bool {
        didSet { applyLaunchAtLogin() }
    }

    @Published var jpegQuality: Double {
        didSet { defaults.set(jpegQuality, forKey: "jpegQuality") }
    }

    @Published var appearanceMode: AppearanceMode {
        didSet {
            defaults.set(appearanceMode.rawValue, forKey: "appearanceMode")
            applyAppearance()
        }
    }

    @Published private(set) var conversionModifier: RadialModifier {
        didSet { defaults.set(conversionModifier.rawValue, forKey: "conversionModifier") }
    }

    @Published private(set) var toolsModifier: RadialModifier {
        didSet { defaults.set(toolsModifier.rawValue, forKey: "toolsModifier") }
    }

    @Published private(set) var actionsModifier: RadialModifier {
        didSet { defaults.set(actionsModifier.rawValue, forKey: "actionsModifier") }
    }

    @Published private(set) var flowModifier: RadialModifier {
        didSet { defaults.set(flowModifier.rawValue, forKey: "flowModifier") }
    }

    @Published private(set) var modifierConflict: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        radialSoundEnabled = defaults.object(forKey: "radialSoundEnabled") as? Bool ?? true
        compressionPreset = CompressionPreset(rawValue: defaults.string(forKey: "compressionPreset") ?? "") ?? .balanced
        compressionResizeLongEdge = defaults.integer(forKey: "compressionResizeLongEdge")
        outputLocation = OutputLocation(rawValue: defaults.string(forKey: "outputLocation") ?? "") ?? .besideOriginal
        revealInFinder = defaults.object(forKey: "revealInFinder") as? Bool ?? true
        progressStyle = ProgressStyle(rawValue: defaults.string(forKey: "progressStyle") ?? "") ?? .card
        ffmpegPath = defaults.string(forKey: "ffmpegPath") ?? ""
        jpegQuality = defaults.object(forKey: "jpegQuality") as? Double ?? 0.9
        appearanceMode = AppearanceMode(rawValue: defaults.string(forKey: "appearanceMode") ?? "") ?? .system
        let storedConversion = RadialModifier(rawValue: defaults.string(forKey: "conversionModifier") ?? "") ?? .shift
        let storedTools = RadialModifier(rawValue: defaults.string(forKey: "toolsModifier") ?? "") ?? .command
        let storedActions = RadialModifier(rawValue: defaults.string(forKey: "actionsModifier") ?? "") ?? .control
        let storedFlow = RadialModifier(rawValue: defaults.string(forKey: "flowModifier") ?? "") ?? .option
        if Set([storedConversion, storedTools, storedActions, storedFlow]).count == 4 {
            conversionModifier = storedConversion
            toolsModifier = storedTools
            actionsModifier = storedActions
            flowModifier = storedFlow
        } else {
            conversionModifier = .shift
            toolsModifier = .command
            actionsModifier = .control
            flowModifier = .option
        }
        modifierConflict = nil
        if #available(macOS 13.0, *) {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        } else {
            launchAtLogin = false
        }
    }

    func applyAppearance() {
        NSApp.appearance = appearanceMode.appearance
    }

    var modifierAssignments: [RadialMode: RadialModifier] {
        [
            .conversion: conversionModifier,
            .tools: toolsModifier,
            .actions: actionsModifier,
            .flow: flowModifier,
        ]
    }

    func modifier(for mode: RadialMode) -> RadialModifier {
        modifierAssignments[mode] ?? mode.defaultModifier
    }

    @discardableResult
    func setModifier(_ modifier: RadialModifier, for mode: RadialMode) -> Bool {
        let duplicate = RadialMode.allCases.first { $0 != mode && self.modifier(for: $0) == modifier }
        if let duplicate {
            modifierConflict = "\(modifier.title) is already assigned to \(duplicate.title). Choose a different modifier."
            return false
        }
        modifierConflict = nil
        switch mode {
        case .conversion: conversionModifier = modifier
        case .tools: toolsModifier = modifier
        case .actions: actionsModifier = modifier
        case .flow: flowModifier = modifier
        }
        return true
    }

    private func applyLaunchAtLogin() {
        guard #available(macOS 13.0, *) else { return }
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Launch at login change failed: \(error)")
        }
    }
}
