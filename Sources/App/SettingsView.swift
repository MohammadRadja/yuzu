import AppKit
import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case appearance
    case shortcuts
    case conversion
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .appearance: return "Appearance"
        case .shortcuts: return "Shortcuts"
        case .conversion: return "Conversion"
        case .about: return "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "paintbrush"
        case .shortcuts: return "command"
        case .conversion: return "arrow.triangle.2.circlepath"
        case .about: return "info.circle"
        }
    }
}

@MainActor
final class SettingsTabModel: ObservableObject {
    @Published var tab: SettingsTab = .general
}

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject var model: SettingsTabModel
    @State private var ffmpegHealth: FFmpeg.Health = .missing

    static let width: CGFloat = 520
    static let height: CGFloat = 540

    var body: some View {
        Form {
            switch model.tab {
            case .general: general
            case .appearance: appearance
            case .shortcuts: shortcuts
            case .conversion: conversion
            case .about: about
            }
        }
        .formStyle(.grouped)
        .id(model.tab)
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.18), value: model.tab)
        .frame(width: Self.width, height: Self.height)
        .tint(Theme.accent)
        .task(id: settings.ffmpegPath) { ffmpegHealth = await FFmpeg.checkHealth() }
    }

    @ViewBuilder private var general: some View {
        Section("Output") {
            Picker("Save converted files", selection: $settings.outputLocation) {
                ForEach(OutputLocation.allCases) { Text($0.title).tag($0) }
            }
            Toggle("Reveal results in Finder", isOn: $settings.revealInFinder)
        }
        Section("General") {
            Toggle("Launch Yuzu at login", isOn: $settings.launchAtLogin)
        }
    }

    @ViewBuilder private var appearance: some View {
        Section("Theme") {
            Picker("Theme", selection: $settings.appearanceMode) {
                ForEach(AppearanceMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
        }
        Section {
            Picker("Progress", selection: $settings.progressStyle) {
                ForEach(ProgressStyle.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
        } header: {
            Text("Progress")
        } footer: {
            Text(
                settings.progressStyle == .card
                    ? "A floating card in the top right corner with the file name and percentage."
                    : "A tiny progress bar in a pill below the notch.")
        }
    }

    @ViewBuilder private var conversion: some View {
        Section {
            LabeledContent("LibreOffice", value: OfficeEngine.executable == nil ? "Not found" : "Available")
        } header: {
            Text("Office conversions")
        } footer: {
            Text(
                "LibreOffice is needed for PowerPoint, Excel, ODS, Pages input, and DOCX/RTF conversion. Install it in Applications. PDF exports to PPTX/XLSX and CSV/TSV conversions use native code."
            )
        }
        Section("Images") {
            HStack {
                Text("JPEG / HEIC / WebP quality")
                Slider(value: $settings.jpegQuality, in: 0.3...1.0)
                Text("\(Int(settings.jpegQuality * 100))%").monospacedDigit().frame(width: 44, alignment: .trailing)
            }
        }
        Section {
            Picker("Preset", selection: $settings.compressionPreset) {
                ForEach(CompressionPreset.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            HStack {
                Text("Resize long edge to")
                TextField("Off", value: $settings.compressionResizeLongEdge, format: .number)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                Text("px (0 = keep size)").foregroundStyle(.secondary)
            }
        } header: {
            Text("Compression")
        } footer: {
            Text(
                settings.compressionPreset == .balanced
                    ? "Balanced keeps detail while trimming size noticeably."
                    : "Strong prioritizes the smallest file, with visible quality loss.")
        }
        Section {
            HStack {
                TextField("Auto-detect (Homebrew, MacPorts, /usr/local/bin)", text: $settings.ffmpegPath)
                    .textFieldStyle(.roundedBorder)
                Button("Choose…") { chooseFFmpeg() }
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: ffmpegHealthSymbol)
                    .foregroundStyle(ffmpegHealthColor)
                Text(ffmpegHealthText)
                    .font(.caption)
                    .textSelection(.enabled)
            }
        } header: {
            Text("FFmpeg (optional)")
        } footer: {
            Text(
                "Yuzu uses Apple frameworks for most work. FFmpeg fills the gaps: MP3, FLAC, OGG, Opus, WMA, MKV, WebM, AVI, WMV, GIF and AVIF/WebP encoding on older systems."
            )
        }
    }

    @ViewBuilder private var shortcuts: some View {
        Section {
            ForEach(RadialMode.allCases) { mode in
                Picker(mode.title, selection: modifierBinding(for: mode)) {
                    ForEach(RadialModifier.allCases) { modifier in
                        Label(modifier.title, systemImage: modifier.symbol).tag(modifier)
                    }
                }
                .accessibilityLabel("\(mode.title) modifier")
            }
        } header: {
            Text("Radial modes")
        } footer: {
            Text(
                "Hold a modifier while dragging files from Finder or the Desktop. Changes apply to the next drag. Shift + Option remains a temporary tools compatibility shortcut."
            )
        }
        if let modifierConflict = settings.modifierConflict {
            Section {
                Label(modifierConflict, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
        Section {
            LabeledContent("Quick Preview", value: "Planned")
            LabeledContent("Float", value: "Planned")
        } header: {
            Text("Not available")
        }
    }

    private func modifierBinding(for mode: RadialMode) -> Binding<RadialModifier> {
        Binding(
            get: { settings.modifier(for: mode) },
            set: { _ = settings.setModifier($0, for: mode) }
        )
    }

    @ViewBuilder private var about: some View {
        Section {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Yuzu").font(.title2.weight(.semibold))
                    Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
        Section {
            LabeledContent("Conversions", value: "\(ConversionMatrix.totalConversions)")
            LabeledContent("Tools", value: "\(ToolID.total)")
        } footer: {
            Text(
                "Hold Shift while dragging files for Convert, Command for Tools, Control for Actions, or Option for Tasks. Everything runs on this Mac; nothing is uploaded."
            )
        }
    }

    private var ffmpegHealthSymbol: String {
        switch ffmpegHealth {
        case .ready: return "checkmark.circle.fill"
        case .broken: return "xmark.octagon.fill"
        case .missing: return "exclamationmark.triangle.fill"
        }
    }

    private var ffmpegHealthColor: Color {
        switch ffmpegHealth {
        case .ready: return .green
        case .broken: return .red
        case .missing: return .orange
        }
    }

    private var ffmpegHealthText: String {
        switch ffmpegHealth {
        case let .ready(path, version): return "Using ffmpeg \(version) at \(path)"
        case let .broken(path, reason): return "ffmpeg at \(path) cannot run: \(reason)"
        case .missing: return "FFmpeg not found. Install with `wax install ffmpeg` or pick the binary."
        }
    }

    private func chooseFFmpeg() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin")
        if panel.runModal() == .OK, let url = panel.url {
            settings.ffmpegPath = url.path
        }
    }
}

struct SettingsTabBar: View {
    @ObservedObject var model: SettingsTabModel
    @Namespace private var namespace

    var body: some View {
        GlassEffectContainer(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(SettingsTab.allCases) { tab in
                    Button {
                        model.tab = tab
                    } label: {
                        Label(tab.title, systemImage: tab.symbol)
                            .labelStyle(.titleOnly)
                            .font(.system(size: 13, weight: model.tab == tab ? .semibold : .regular))
                            .foregroundStyle(model.tab == tab ? Color.white : Color.primary)
                            .lineLimit(1)
                            .fixedSize()
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .background {
                        if model.tab == tab {
                            Color.clear
                                .glassEffect(.regular.tint(Theme.accent).interactive(), in: Capsule())
                                .matchedGeometryEffect(id: "selection", in: namespace)
                        }
                    }
                }
            }
            .padding(3)
            .glassEffect(.regular, in: Capsule())
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: model.tab)
    }
}

final class SettingsWindow: NSWindow {
    var toolbarDelegate: SettingsToolbarDelegate?
}

@MainActor
final class SettingsToolbarDelegate: NSObject, NSToolbarDelegate {
    static let tabsItem = NSToolbarItem.Identifier("yuzu.settings.tabs")
    let model: SettingsTabModel

    init(model: SettingsTabModel) {
        self.model = model
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.tabsItem, .flexibleSpace]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard itemIdentifier == Self.tabsItem else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        let hosting = NSHostingView(rootView: SettingsTabBar(model: model))
        hosting.sizingOptions = [.intrinsicContentSize]
        item.view = hosting
        item.isBordered = false
        return item
    }
}
