import Foundation

/// The controller's single authority for hover, cancellation and exactly-once drop dispatch.
/// Terminal states retain the ID so late callbacks cannot reopen the same drag.
struct RadialDragSession {
    enum Phase: Equatable {
        case idle
        case dragging
        case radialPresented
        case hoveringWedge(Int)
        case committing
        case completed
        case cancelled
        case failed
    }

    private(set) var phase: Phase = .idle
    private(set) var id: UUID?
    private(set) var urls: [URL] = []
    private(set) var sequenceNumber: Int?

    var isActive: Bool {
        switch phase {
        case .dragging, .radialPresented, .hoveringWedge: return true
        default: return false
        }
    }

    @discardableResult
    mutating func begin(id: UUID, urls: [URL]) -> Bool {
        guard self.id != id, !isActive, phase != .committing else { return false }
        self.id = id
        self.urls = FileSelection(urls: urls).urls
        sequenceNumber = nil
        phase = .dragging
        return true
    }

    mutating func present() {
        guard phase == .dragging else { return }
        phase = .radialPresented
    }

    @discardableResult
    mutating func bind(sequenceNumber: Int) -> Bool {
        guard isActive, self.sequenceNumber == nil || self.sequenceNumber == sequenceNumber else { return false }
        self.sequenceNumber = sequenceNumber
        return true
    }

    mutating func updateURLs(_ urls: [URL]) {
        guard isActive else { return }
        let normalized = FileSelection(urls: urls).urls
        guard normalized != self.urls else { return }
        self.urls = normalized
        hover(nil)
    }

    mutating func hover(_ index: Int?) {
        guard phase == .radialPresented || isHovering else { return }
        phase = index.map(Phase.hoveringWedge) ?? .radialPresented
    }

    /// Only the native destination's performDragOperation may call this method.
    mutating func commit(id: UUID, sequenceNumber: Int, index: Int) -> Bool {
        guard self.id == id, self.sequenceNumber == sequenceNumber,
            !urls.isEmpty, index >= 0, phase == .hoveringWedge(index)
        else { return false }
        phase = .committing
        return true
    }

    mutating func complete() {
        guard phase == .committing else { return }
        finish(.completed)
    }

    mutating func cancel() {
        guard isActive else { return }
        finish(.cancelled)
    }

    mutating func fail() {
        guard isActive || phase == .committing else { return }
        finish(.failed)
    }

    private var isHovering: Bool {
        if case .hoveringWedge = phase { return true }
        return false
    }

    private mutating func finish(_ phase: Phase) {
        self.phase = phase
        urls = []
        sequenceNumber = nil
    }
}
