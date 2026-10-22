import AppKit

/// All values are AppKit screen points, including negative display origins. No
/// backing-scale conversion is needed: AppKit and SwiftUI both lay out in points.
enum RadialPlacement {
    static func frame(anchoredAt point: NSPoint, in screen: NSRect, diameter: CGFloat) -> NSRect {
        let size = min(diameter, min(screen.width, screen.height))
        let radius = size / 2
        let center = NSPoint(
            x: min(max(point.x, screen.minX + radius), screen.maxX - radius),
            y: min(max(point.y, screen.minY + radius), screen.maxY - radius)
        )
        return NSRect(x: center.x - radius, y: center.y - radius, width: size, height: size)
    }
}

final class RadialPanel: NSPanel {
    let radialView = RadialView(frame: .zero)

    init(frame: NSRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .popUpMenu
        ignoresMouseEvents = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        hidesOnDeactivate = false
        acceptsMouseMovedEvents = true
        radialView.frame = contentView?.bounds ?? .zero
        radialView.autoresizingMask = [.width, .height]
        contentView = radialView
    }

    override var canBecomeKey: Bool { true }
}

@MainActor
final class RadialController: DragMonitorDelegate {
    private var panel: RadialPanel?
    private var urls: [URL] = []
    private var mode: RadialMode = .conversion
    private var session = RadialDragSession()
    private var visible = false
    private var pickerMode = false
    private var outsideClickMonitor: Any?
    private var releaseTimer: Timer?
    private var destinationChangeCount: Int?
    private var nativeDropPrepared = false
    private let fileActions = FileActionHandler()

    weak var dragMonitor: DragMonitor?

    func dragMonitor(_ monitor: DragMonitor, didUpdate update: DragSessionUpdate) {
        guard !pickerMode, let updateMode = update.mode else { return }
        dragMonitor = monitor
        if session.id != update.id {
            if session.isActive { cancel() }
            guard update.dragConfirmed, !update.urls.isEmpty,
                session.begin(id: update.id, urls: update.urls)
            else { return }
            guard present(urls: update.urls, at: update.point, mode: updateMode) else {
                session.fail()
                monitor.markHandled(sessionID: update.id)
                return
            }
            session.present()
            DragDebug.log("radial presented id=\(update.id) frame=\(panel?.frame ?? .zero) mode=\(updateMode.rawValue)")
        }
        guard session.isActive, visible else { return }
        // Keep the panel anchored for the entire gesture. Only the cursor moves.
        if session.sequenceNumber == nil {
            guard !update.urls.isEmpty else {
                cancel()
                return
            }
            updateSelection(update.urls)
        }
        if updateMode != mode {
            DragDebug.log("mode change \(mode.rawValue) -> \(updateMode.rawValue)")
            mode = updateMode
            reloadItems()
        }
        panel?.radialView.updateHighlight(forScreenPoint: update.point)
    }

    func dragMonitorDidEndDrag(_ monitor: DragMonitor, sessionID: UUID, at point: NSPoint) {
        guard !pickerMode, session.id == sessionID, session.isActive else { return }
        DragDebug.log("release observed id=\(sessionID) screen=\(point); awaiting native completion")
        // An accepted native drop may wait for the source's drag-image animation.
        // AppKit's perform/ended callbacks own completion once preparation succeeds.
        guard !nativeDropPrepared else { return }
        releaseTimer?.invalidate()
        let timer = Timer(timeInterval: 0.25, repeats: false) { [weak self] _ in
            guard let self, self.session.id == sessionID, self.session.isActive else { return }
            DragDebug.log("release without accepted native drop; cancelling id=\(sessionID)")
            self.cancel()
        }
        releaseTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func presentPicker(for urls: [URL], mode: RadialMode = .conversion) {
        if session.isActive { cancel() }
        pickerMode = true
        guard present(urls: urls, at: NSEvent.mouseLocation, mode: mode) else {
            hidePresentation()
            return
        }
        panel?.makeKeyAndOrderFront(nil)
        panel?.makeFirstResponder(panel?.radialView)
        NSApp.activate(ignoringOtherApps: true)
        installOutsideClickMonitor()
    }

    // Compatibility entry point for the menu bar and screenshot driver.
    func presentPicker(for urls: [URL], advanced: Bool) {
        presentPicker(for: urls, mode: advanced ? .tools : .conversion)
    }

    private func present(urls: [URL], at point: NSPoint, mode: RadialMode) -> Bool {
        self.urls = FileSelection(urls: urls).urls
        self.mode = mode
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) ?? NSScreen.main ?? NSScreen.screens.first else {
            DragDebug.log("presentation failed: no screen available")
            return false
        }
        let diameter = RadialGeometry(count: 0).canvasDiameter
        let frame = RadialPlacement.frame(anchoredAt: point, in: screen.visibleFrame, diameter: diameter)
        let panel = self.panel ?? RadialPanel(frame: frame)
        panel.setFrame(frame, display: false)
        self.panel = panel
        let view = panel.radialView
        view.center = NSPoint(x: view.bounds.midX, y: view.bounds.midY)
        view.interactive = pickerMode
        view.onSelect = { [weak self] item in self?.selectPickerItem(item) }
        view.onCancel = { [weak self] in self?.cancel() }
        let id = session.id
        view.onDragUpdate = { [weak self] info in
            guard let self, let id, self.session.id == id else { return false }
            return self.acceptNativeDrag(info)
        }
        view.onDrop = { [weak self] info in
            guard let self, let id, self.session.id == id else { return false }
            return self.commitDrop(info)
        }
        view.onPrepareDrop = { [weak self] info in
            guard let self, self.session.id == id, self.session.isActive,
                self.session.sequenceNumber == info.draggingSequenceNumber
            else { return false }
            self.nativeDropPrepared = true
            self.releaseTimer?.invalidate()
            self.releaseTimer = nil
            return true
        }
        view.onDragEnd = { [weak self] info in
            guard let self, self.session.id == id, self.session.isActive,
                self.session.sequenceNumber == info.draggingSequenceNumber
            else { return }
            DragDebug.log("native drag completion without commit sequence=\(info.draggingSequenceNumber)")
            self.cancel()
        }
        view.onHoverChanged = { [weak self] index in
            guard let self, self.session.id == id, !self.pickerMode else { return }
            self.session.hover(index)
        }
        destinationChangeCount = nil
        reloadItems()
        view.layoutSubtreeIfNeeded()
        visible = true
        panel.orderFrontRegardless()
        return true
    }

    private func acceptNativeDrag(_ info: NSDraggingInfo) -> Bool {
        guard !pickerMode, visible, session.bind(sequenceNumber: info.draggingSequenceNumber) else { return false }
        let change = info.draggingPasteboard.changeCount
        if destinationChangeCount != change || session.urls.isEmpty {
            destinationChangeCount = change
            let dragged = DragMonitor.fileURLs(on: info.draggingPasteboard)
            DragDebug.log("native URLs sequence=\(info.draggingSequenceNumber) count=\(dragged.count)")
            updateSelection(dragged)
            if let id = session.id { dragMonitor?.adoptNativeURLs(dragged, sessionID: id) }
        }
        return !session.urls.isEmpty
    }

    private func updateSelection(_ dragged: [URL]) {
        let normalized = FileSelection(urls: dragged).urls
        session.updateURLs(normalized)
        guard normalized != urls else { return }
        urls = normalized
        reloadItems()
    }

    private func reloadItems() {
        guard let view = panel?.radialView else { return }
        session.hover(nil)
        view.clearHighlight()
        let content = RadialProvider.content(for: urls, mode: mode)
        view.configure(content: content, mode: mode)
    }

    private func commitDrop(_ info: NSDraggingInfo) -> Bool {
        guard acceptNativeDrag(info), let view = panel?.radialView, let id = session.id else { return false }
        // Re-read at the point of dispatch. A missing/replaced selection must not
        // execute an item displayed for another file or a stale pasteboard.
        let droppedURLs = DragMonitor.fileURLs(on: info.draggingPasteboard)
        guard droppedURLs == session.urls, !droppedURLs.isEmpty else {
            DragDebug.log("drop failed: selection changed or files unavailable")
            session.fail()
            dragMonitor?.markHandled(sessionID: id)
            hidePresentation()
            return false
        }
        view.updateHighlight(forWindowPoint: info.draggingLocation)
        guard let index = view.highlighted, view.items.indices.contains(index),
            session.commit(id: id, sequenceNumber: info.draggingSequenceNumber, index: index)
        else { return false }
        let item = view.items[index]
        DragDebug.log("committing id=\(id) sequence=\(info.draggingSequenceNumber) wedge=\(index) action=\(item.detail)")
        dragMonitor?.markHandled(sessionID: id)
        session.complete()
        // Claim synchronously; run UI/actions only after AppKit returns from the drop.
        hidePresentation()
        dispatch(item, urls: droppedURLs)
        DragDebug.log("drag completed id=\(id)")
        return true
    }

    private func selectPickerItem(_ item: RadialItem) {
        guard pickerMode, visible, panel?.radialView.items.contains(item) == true else { return }
        let selectedURLs = urls
        hidePresentation()
        dispatch(item, urls: selectedURLs)
    }

    private func dispatch(_ item: RadialItem, urls selectedURLs: [URL]) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            DragDebug.log("action execution \(item.detail) files=\(selectedURLs.count)")
            switch item.action {
            case .convert(let target):
                JobRunner.shared.convert(selectedURLs, to: target)
            case .tool(let tool):
                ToolWindowManager.shared.open(tool, files: selectedURLs)
            case .file(let action):
                fileActions.perform(action, urls: selectedURLs) { [weak self] message in self?.showError(message) }
            }
        }
    }

    private func cancel() {
        if !pickerMode {
            DragDebug.log("drag cancellation id=\(session.id?.uuidString ?? "-") state=\(session.phase)")
            session.cancel()
            if let id = session.id { dragMonitor?.markHandled(sessionID: id) }
        }
        hidePresentation()
    }

    func highlight(_ index: Int) { panel?.radialView.highlight(index) }

    func hide() { cancel() }

    private func hidePresentation() {
        releaseTimer?.invalidate()
        releaseTimer = nil
        visible = false
        pickerMode = false
        urls = []
        destinationChangeCount = nil
        nativeDropPrepared = false
        panel?.radialView.reset()
        panel?.orderOut(nil)
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
    }

    private func installOutsideClickMonitor() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.cancel()
        }
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Yuzu couldn’t complete that action"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
