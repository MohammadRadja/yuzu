import AppKit
import Quartz
import SwiftUI

private struct CloseFeatureWindowKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

extension EnvironmentValues {
    var closeFeatureWindow: () -> Void {
        get { self[CloseFeatureWindowKey.self] }
        set { self[CloseFeatureWindowKey.self] = newValue }
    }
}

@MainActor
private final class FeatureWindowHandle {
    weak var window: NSWindow?
    func close() { window?.close() }
}

@MainActor
final class FeatureWindows: NSObject, NSWindowDelegate {
    static let shared = FeatureWindows()
    private var windows: [NSWindow] = []
    var openWindows: [NSWindow] { windows }
    func closeAll() { let current = windows; for window in current { window.close() } }

    @discardableResult
    func show<Content: View>(_ title: String, size: NSSize = NSSize(width: 640, height: 480), @ViewBuilder content: () -> Content) -> NSWindow {
        let handle = FeatureWindowHandle()
        let view = content().tint(Theme.accent).environment(\.closeFeatureWindow, { handle.close() })
            .defaultAppStorage(ValidationRuntime.isolatedDefaults ?? .standard)
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        handle.window = window
        window.title = title
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(size)
        window.minSize = NSSize(width: min(680, size.width), height: min(480, size.height))
        window.isReleasedWhenClosed = false
        window.delegate = self
        windows.append(window)
        window.center()
        ValidationRuntime.present(window, activate: true)
        return window
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        windows.removeAll { $0 === window }
    }
}

@MainActor
final class FilePreview: NSObject, @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate {
    static let shared = FilePreview()
    private var urls: [URL] = []

    func show(_ urls: [URL]) {
        self.urls = urls
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.currentPreviewItemIndex = 0
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        guard urls.indices.contains(index) else { return nil }
        return urls[index] as NSURL
    }
    func windowWillClose(_ notification: Notification) {
        urls = []
        (notification.object as? QLPreviewPanel)?.dataSource = nil
    }
}

struct MoreActionsView: View {
    let items: [RadialItem]
    let perform: (RadialItem) -> Void

    var body: some View {
        List(items) { item in
            Button {
                perform(item)
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.label).font(.headline)
                        Text(item.detail).font(.callout).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: item.symbol).frame(width: 28)
                }
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("radial.more." + item.label)
        }
        .padding(12)
    }
}
