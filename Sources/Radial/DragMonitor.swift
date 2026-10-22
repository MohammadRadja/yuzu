import AppKit

@MainActor
protocol DragMonitorDelegate: AnyObject {
    func dragMonitor(_ monitor: DragMonitor, didUpdate update: DragSessionUpdate)
    func dragMonitorDidEndDrag(_ monitor: DragMonitor, sessionID: UUID, at point: NSPoint)
}

enum DragDebug {
    static let enabled = ProcessInfo.processInfo.environment["YUZU_DEBUG_DRAG"] != nil
    private static let queue = DispatchQueue(label: "com.radja.yuzu.drag-debug", qos: .utility)
    private static let handle: FileHandle? = {
        guard enabled else { return nil }
        let path = ProcessInfo.processInfo.environment["YUZU_DEBUG_DRAG"].flatMap { $0.hasPrefix("/") ? $0 : nil } ?? "/tmp/yuzu-drag.log"
        if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
        let handle = FileHandle(forWritingAtPath: path)
        handle?.seekToEndOfFile()
        return handle
    }()

    static func log(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        let data = Data((String(format: "%.3f ", Date().timeIntervalSince1970) + message() + "\n").utf8)
        queue.async {
            guard let handle else { return }
            try? handle.write(contentsOf: data)
        }
    }
}

@MainActor
final class DragMonitor {
    weak var delegate: DragMonitorDelegate?

    private var monitors: [Any] = []
    private var pollTimer: Timer?
    private var idleChangeCount = 0
    private var pressChangeCount = 0
    private var lastReadChange = 0
    private var activeURLs: [URL] = []
    private var presenting = false
    private var handled = false
    private var mouseDown = false
    private var sessionID: UUID?
    private var assignments: [RadialMode: RadialModifier] = [:]
    private var modeResolver = RadialModeResolver(assignments: [:])
    private var lastFlags: NSEvent.ModifierFlags = []
    private var lastReadTime = Date.distantPast
    private var nativePasteboardChange: Int?

    private static let idleInterval = 1.0 / 30.0
    private static let dragInterval = 1.0 / 60.0

    func start() {
        stop()
        idleChangeCount = NSPasteboard(name: .drag).changeCount
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .flagsChanged]
        if let monitor = NSEvent.addGlobalMonitorForEvents(
            matching: mask,
            handler: { [weak self] event in
                self?.observe(event)
            })
        {
            monitors.append(monitor)
        }
        if let monitor = NSEvent.addLocalMonitorForEvents(
            matching: mask,
            handler: { [weak self] event in
                self?.observe(event)
                return event
            })
        {
            monitors.append(monitor)
        }
        schedulePoll(interval: Self.idleInterval)
        DragDebug.log("monitor started monitors=\(monitors.count) pasteboard=\(idleChangeCount)")
    }

    func stop() {
        if let sessionID, presenting {
            delegate?.dragMonitorDidEndDrag(self, sessionID: sessionID, at: NSEvent.mouseLocation)
        }
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        pollTimer?.invalidate()
        pollTimer = nil
        resetSession()
    }

    func markHandled(sessionID: UUID) {
        guard self.sessionID == sessionID else { return }
        handled = true
        presenting = false
        activeURLs = []
    }

    /// Native destination URLs are authoritative for this press, including when the
    /// source published its pasteboard before the first observable dragged event.
    func adoptNativeURLs(_ urls: [URL], sessionID: UUID) {
        guard self.sessionID == sessionID, !handled else { return }
        activeURLs = urls
        nativePasteboardChange = NSPasteboard(name: .drag).changeCount
    }

    private func observe(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            beginPressIfNeeded(baseline: NSPasteboard(name: .drag).changeCount)
        case .leftMouseDragged:
            beginPressIfNeeded(baseline: idleChangeCount)
            poll()
        case .leftMouseUp:
            DragDebug.log("mouse release screen=\(NSEvent.mouseLocation)")
            finishPress()
        case .flagsChanged:
            if mouseDown { evaluateModifiers() }
        default: break
        }
    }

    private func schedulePoll(interval: TimeInterval) {
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.poll() }
        timer.tolerance = interval / 4
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private var buttonPressed: Bool { NSEvent.pressedMouseButtons & 1 == 1 }

    private func beginPressIfNeeded(baseline: Int) {
        guard !mouseDown else { return }
        resetSession()
        mouseDown = true
        sessionID = UUID()
        assignments = AppSettings.shared.modifierAssignments
        modeResolver = RadialModeResolver(assignments: assignments)
        pressChangeCount = baseline
        lastReadChange = baseline
        schedulePoll(interval: Self.dragInterval)
        DragDebug.log("session start id=\(sessionID?.uuidString ?? "-") screen=\(NSEvent.mouseLocation) pasteboard=\(baseline)")
    }

    private func poll() {
        guard buttonPressed else {
            if mouseDown { finishPress() }
            idleChangeCount = NSPasteboard(name: .drag).changeCount
            return
        }
        beginPressIfNeeded(baseline: idleChangeCount)
        guard !handled else { return }
        refreshDragPasteboard()
        evaluateModifiers()
    }

    private func refreshDragPasteboard() {
        let pasteboard = NSPasteboard(name: .drag)
        let change = pasteboard.changeCount
        // Movement alone is not evidence of a file drag. Never reuse idle contents.
        guard change != pressChangeCount else { return }
        let changed = change != lastReadChange
        // Some sources supply URL data lazily without changing the generation again.
        guard changed || (activeURLs.isEmpty && Date().timeIntervalSince(lastReadTime) >= 0.1) else { return }
        lastReadChange = change
        lastReadTime = Date()
        if nativePasteboardChange == change { return }
        activeURLs = Self.fileURLs(on: pasteboard)
        DragDebug.log("pasteboard detection generation=\(change) urls=\(activeURLs.count) types=\(pasteboard.types?.map(\.rawValue) ?? [])")
    }

    nonisolated static func fileURLs(on pasteboard: NSPasteboard) -> [URL] {
        let readURLs = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        let fallbackURLs = (pasteboard.pasteboardItems ?? []).compactMap { item in
            item.string(forType: .fileURL).flatMap { URL(string: $0) }
        }
        return normalizeURLs(readURLs + fallbackURLs)
    }

    nonisolated static func normalizeURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<URL>()
        return urls.compactMap { url in
            let resolved = (url as NSURL).filePathURL ?? url
            guard resolved.isFileURL else { return nil }
            let standardized = resolved.standardizedFileURL
            guard FileManager.default.fileExists(atPath: standardized.path), seen.insert(standardized).inserted else { return nil }
            return standardized
        }
    }

    private func evaluateModifiers() {
        guard mouseDown, !handled, !activeURLs.isEmpty || presenting, let sessionID else { return }
        let flags = NSEvent.modifierFlags
        let mode = modeResolver.resolve(flags)
        if flags != lastFlags {
            DragDebug.log("modifiers flags=\(flags.rawValue) mode=\(mode?.rawValue ?? "none") legacy=\(modeResolver.usingLegacyAlias)")
            lastFlags = flags
        }
        guard mode != nil, !activeURLs.isEmpty || presenting else { return }
        presenting = true
        // AppKit monitors and this timer run on main. Deliver in order: no queued
        // update can resurrect a cancelled session after a native end callback.
        delegate?.dragMonitor(
            self,
            didUpdate: DragSessionUpdate(
                id: sessionID, urls: activeURLs, mode: mode,
                point: NSEvent.mouseLocation, dragConfirmed: !activeURLs.isEmpty
            ))
    }

    private func finishPress() {
        guard mouseDown else { return }
        let endedSession = sessionID
        let wasPresenting = presenting
        let releasePoint = NSEvent.mouseLocation
        DragDebug.log("physical press ended id=\(endedSession?.uuidString ?? "-") screen=\(releasePoint)")
        resetSession()
        idleChangeCount = NSPasteboard(name: .drag).changeCount
        schedulePoll(interval: Self.idleInterval)
        if wasPresenting, let endedSession {
            // This reports release only. The controller gives AppKit time to finish
            // its native drop, then cancels any remaining session; it never commits.
            delegate?.dragMonitorDidEndDrag(self, sessionID: endedSession, at: releasePoint)
        }
    }

    private func resetSession() {
        mouseDown = false
        presenting = false
        activeURLs = []
        sessionID = nil
        assignments = [:]
        modeResolver = RadialModeResolver(assignments: [:])
        handled = false
        nativePasteboardChange = nil
        lastReadTime = .distantPast
        lastFlags = []
    }
}
