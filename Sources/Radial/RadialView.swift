import AppKit
import SwiftUI

struct RadialGeometry {
    var innerRadius: CGFloat = Theme.radialHubRadius + Theme.radialHubSeparation
    var outerRadius: CGFloat = Theme.radialOuterRadius
    var gap: CGFloat = Theme.radialSegmentGap
    var count: Int

    var slice: CGFloat { 2 * .pi / CGFloat(max(count, 1)) }

    var corner: CGFloat {
        let wanted = Theme.radialSegmentCorner
        let limit = (innerRadius * sin(slice * 0.34) - gap / 2) / (1 - sin(slice * 0.34))
        return max(4, min(wanted, limit))
    }

    var labelRadius: CGFloat { innerRadius + (outerRadius - innerRadius) * 0.56 }

    var labelWidth: CGFloat {
        guard count > 1 else { return 144 }
        let chord = 2 * labelRadius * sin(slice / 2)
        return min(144, max(28, chord - 10))
    }

    var canvasDiameter: CGFloat { outerRadius * 2 + 32 }

    private var canvasRect: CGRect {
        CGRect(x: 0, y: 0, width: canvasDiameter, height: canvasDiameter)
    }

    func angles(for index: Int) -> (start: CGFloat, end: CGFloat) {
        let end = CGFloat.pi / 2 - slice * CGFloat(index) + slice / 2
        return (end - slice, end)
    }

    func midpoint(for index: Int, in rect: CGRect) -> CGPoint {
        let (start, end) = angles(for: index)
        let mid = (start + end) / 2
        return CGPoint(x: rect.midX + cos(mid) * labelRadius, y: rect.midY - sin(mid) * labelRadius)
    }

    /// Offset from the dial center in SwiftUI coordinates: positive y points down.
    func index(at offset: CGPoint) -> Int? {
        guard count > 0 else { return nil }
        let distance = hypot(offset.x, offset.y)
        guard distance >= innerRadius, distance <= outerRadius else { return nil }
        let point = CGPoint(x: offset.x + canvasDiameter / 2, y: offset.y + canvasDiameter / 2)
        for index in 0..<count {
            let wedge = WedgeShape(geometry: self, index: index)
            if wedge.path(in: canvasRect).contains(point) {
                return index
            }
        }
        return nil
    }
}

struct WedgeShape: Shape {
    var geometry: RadialGeometry
    var index: Int

    func path(in rect: CGRect) -> Path {
        guard geometry.count > 0, (0..<geometry.count).contains(index) else { return Path() }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let (a0, a1) = geometry.angles(for: index)
        let r0 = geometry.innerRadius
        let r1 = geometry.outerRadius
        guard geometry.count > 1 else {
            // Opposite winding keeps the hub empty under the default fill rule,
            // so drawing and Path.contains agree for a single action as well.
            var ring = Path()
            ring.addArc(center: center, radius: r1, startAngle: .zero, endAngle: .radians(2 * .pi), clockwise: false)
            ring.closeSubpath()
            ring.move(to: CGPoint(x: center.x + r0, y: center.y))
            ring.addArc(center: center, radius: r0, startAngle: .zero, endAngle: .radians(-2 * .pi), clockwise: true)
            ring.closeSubpath()
            return ring
        }
        let k = geometry.corner
        let half = geometry.gap / 2
        let phiOuter = asin(min(0.98, (k + half) / max(r1 - k, 1)))
        let phiInner = asin(min(0.98, (k + half) / max(r0 + k, 1)))

        func point(_ radius: CGFloat, _ angle: CGFloat) -> CGPoint {
            CGPoint(x: center.x + cos(angle) * radius, y: center.y - sin(angle) * radius)
        }
        func normal(_ angle: CGFloat, inward: Bool) -> CGVector {
            inward ? CGVector(dx: sin(angle), dy: -cos(angle)) : CGVector(dx: -sin(angle), dy: cos(angle))
        }
        func offset(_ point: CGPoint, _ vector: CGVector, _ distance: CGFloat) -> CGPoint {
            CGPoint(x: point.x + vector.dx * distance, y: point.y - vector.dy * distance)
        }
        func arc(_ path: inout Path, center: CGPoint, radius: CGFloat, from: CGPoint, to: CGPoint) {
            let start = atan2(from.y - center.y, from.x - center.x)
            let end = atan2(to.y - center.y, to.x - center.x)
            path.addArc(center: center, radius: radius, startAngle: .radians(start), endAngle: .radians(end), clockwise: true)
        }

        let outerEndCenter = point(r1 - k, a1 - phiOuter)
        let outerEndTangent = offset(outerEndCenter, normal(a1, inward: true), -k)
        let innerEndCenter = point(r0 + k, a1 - phiInner)
        let innerEndTangent = offset(innerEndCenter, normal(a1, inward: true), -k)
        let innerStartCenter = point(r0 + k, a0 + phiInner)
        let innerStartTangent = offset(innerStartCenter, normal(a0, inward: false), -k)
        let outerStartCenter = point(r1 - k, a0 + phiOuter)
        let outerStartTangent = offset(outerStartCenter, normal(a0, inward: false), -k)

        var path = Path()
        path.move(to: point(r1, a0 + phiOuter))
        path.addArc(center: center, radius: r1, startAngle: .radians(-(a0 + phiOuter)), endAngle: .radians(-(a1 - phiOuter)), clockwise: true)
        arc(&path, center: outerEndCenter, radius: k, from: point(r1, a1 - phiOuter), to: outerEndTangent)
        path.addLine(to: innerEndTangent)
        arc(&path, center: innerEndCenter, radius: k, from: innerEndTangent, to: point(r0, a1 - phiInner))
        path.addArc(center: center, radius: r0, startAngle: .radians(-(a1 - phiInner)), endAngle: .radians(-(a0 + phiInner)), clockwise: false)
        arc(&path, center: innerStartCenter, radius: k, from: point(r0, a0 + phiInner), to: innerStartTangent)
        path.addLine(to: outerStartTangent)
        arc(&path, center: outerStartCenter, radius: k, from: outerStartTangent, to: point(r1, a0 + phiOuter))
        path.closeSubpath()
        return path
    }
}

struct RadialWheelView: View {
    var items: [RadialItem]
    var highlighted: Int?
    var mode: RadialMode
    var context: String
    var fileName: String? = nil
    var isDragging: Bool = false
    var emptyMessage: String
    var emptyDetail: String
    var geometry: RadialGeometry
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        ZStack {
            if items.isEmpty {
                empty
            } else {
                backdrop
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    wedge(item, index: index)
                }
                hub
            }
        }
        .frame(width: geometry.canvasDiameter, height: geometry.canvasDiameter)
        .foregroundStyle(Theme.radialInk)
        .environment(\.colorScheme, .light)
        // Hover feedback must match the current hit region immediately. Mode
        // changes also keep the dial at its actual size and position.
        .transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
    }

    private var backdrop: some View {
        Circle()
            .fill(Theme.radialBackdrop.opacity(reduceTransparency ? 1 : Theme.radialBackdropOpacity))
            .background {
                if !reduceTransparency {
                    Color.clear.glassEffect(.regular.tint(Theme.radialGlassTint), in: Circle())
                }
            }
            .overlay {
                Circle().strokeBorder(
                    contrast == .increased ? Theme.radialInk : Theme.radialRim,
                    lineWidth: contrast == .increased ? 2 : 1)
            }
            .frame(
                width: (geometry.outerRadius + Theme.radialBackdropInset) * 2,
                height: (geometry.outerRadius + Theme.radialBackdropInset) * 2
            )
            .shadow(color: Theme.radialBackdropShadow, radius: 7, y: 3)
            .accessibilityHidden(true)
            .allowsHitTesting(false)
    }

    private func wedge(_ item: RadialItem, index: Int) -> some View {
        let shape = WedgeShape(geometry: geometry, index: index)
        let selected = highlighted == index
        return GeometryReader { proxy in
            let rect = CGRect(origin: .zero, size: proxy.size)
            let mid = geometry.midpoint(for: index, in: rect)
            ZStack {
                if selected {
                    shape.fill(Theme.yuzuYellow)
                        .shadow(color: Theme.activeShadow, radius: 8, y: 3)
                } else {
                    shape.fill(Theme.radialSurfaceGradient)
                        .opacity(reduceTransparency ? 1 : Theme.radialSurfaceOpacity)
                }
                shape.stroke(wedgeStroke(selected: selected), lineWidth: selected || contrast == .increased ? 2 : 1)
                label(item, selected: selected)
                    .frame(width: geometry.labelWidth)
                    .position(mid)
                    .help(item.detail)
            }
            .frame(width: rect.width, height: rect.height)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(item.detail)
            .accessibilityAddTraits(selected ? [.isSelected] : [])
        }
    }

    private func label(_ item: RadialItem, selected: Bool) -> some View {
        let dense = items.count > 8
        return VStack(spacing: dense ? 3 : 5) {
            Image(systemName: item.symbol)
                .font(.system(size: dense ? 17 : Theme.radialIconSize, weight: .medium))
                .symbolRenderingMode(.hierarchical)
            Text(item.label)
                .font(.system(size: dense ? 10 : Theme.radialLabelSize, weight: .semibold))
                .lineLimit(2)
                .minimumScaleFactor(0.66)
                .allowsTightening(true)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(selected ? Theme.yuzuActiveText : Theme.radialInk)
        .contentShape(Rectangle())
    }

    private var hub: some View {
        let selectedItem = highlighted.flatMap { items.indices.contains($0) ? items[$0] : nil }
        let caption = isDragging ? context : (fileName ?? context)
        return VStack(spacing: 4) {
            Image(systemName: selectedItem?.symbol ?? mode.symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.yuzuActiveText)
                .padding(7)
                .background(
                    Circle()
                        .fill(selectedItem == nil ? Theme.yuzuCream : Theme.yuzuYellow)
                )
            Text(selectedItem?.label ?? mode.title)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(caption)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.radialCaption)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 10)
        .frame(width: Theme.radialHubDiameter, height: Theme.radialHubDiameter)
        .background {
            Circle().fill(Theme.radialHub.opacity(reduceTransparency ? 1 : Theme.radialHubOpacity))
        }
        .overlay(Circle().stroke(contrast == .increased ? Theme.radialInk : Theme.radialRim, lineWidth: contrast == .increased ? 2 : 1))
        .shadow(color: Theme.radialHubShadow, radius: 6, y: 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(selectedItem.map { "\($0.detail), \(fileName ?? context)" } ?? "\(mode.title), \(fileName ?? context)")
    }

    private var empty: some View {
        VStack(spacing: 5) {
            Image(systemName: mode.symbol)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(Theme.deepAccent)
            Text(emptyMessage)
                .font(.system(size: 14, weight: .semibold))
                .multilineTextAlignment(.center)
            if !emptyDetail.isEmpty {
                Text(emptyDetail)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.radialCaption)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
        .frame(width: geometry.outerRadius * 2 - 20)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Theme.radialHub.opacity(reduceTransparency ? 1 : Theme.radialHubOpacity))
                .background {
                    if !reduceTransparency {
                        Color.clear.glassEffect(.regular.tint(Theme.radialGlassTint), in: .rect(cornerRadius: 22))
                    }
                }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(
                contrast == .increased ? Theme.radialInk : Theme.radialStroke, lineWidth: contrast == .increased ? 2 : 1)
        )
        .shadow(color: Color.black.opacity(0.18), radius: 9, y: 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(emptyMessage). \(emptyDetail)")
    }

    private func wedgeStroke(selected: Bool) -> Color {
        if contrast == .increased { return selected ? Theme.yuzuActiveText : Theme.radialInk }
        return selected ? Theme.yuzuAmber.opacity(0.9) : Theme.radialStroke
    }
}

final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class RadialView: NSView {
    var items: [RadialItem] = [] {
        didSet {
            guard oldValue != items else { return }
            highlighted = nil
            refresh()
        }
    }
    var emptyMessage = "Waiting for files" { didSet { refresh() } }
    var emptyDetail = "" { didSet { refresh() } }
    var context = "" { didSet { refresh() } }
    var fileName: String? { didSet { refresh() } }
    var mode: RadialMode = .conversion { didSet { refresh() } }
    var center: NSPoint = .zero { didSet { needsLayout = true } }
    var onSelect: ((RadialItem) -> Void)?
    var onCancel: (() -> Void)?
    var onDragUpdate: ((NSDraggingInfo) -> Bool)?
    var onDrop: ((NSDraggingInfo) -> Bool)?
    var onPrepareDrop: ((NSDraggingInfo) -> Bool)?
    var onDragEnd: ((NSDraggingInfo) -> Void)?
    var onHoverChanged: ((Int?) -> Void)?
    var interactive = false { didSet { refresh() } }

    private(set) var highlighted: Int? {
        didSet {
            guard oldValue != highlighted else { return }
            if highlighted != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .drawCompleted)
            }
            DragDebug.log("hover changed wedge=\(highlighted.map(String.init) ?? "none")")
            onHoverChanged?(highlighted)
            refresh()
        }
    }
    private var updatingPresentation = false
    private var nativeDragAllowed: Bool?
    private var lastCoordinateLog = Date.distantPast
    private var trackingArea: NSTrackingArea?
    private let host: PassthroughHostingView<RadialWheelView>

    let discRadius: CGFloat = Theme.radialOuterRadius + 16

    private var geometry: RadialGeometry { RadialGeometry(count: items.count) }

    override init(frame frameRect: NSRect) {
        host = PassthroughHostingView(
            rootView: RadialWheelView(
                items: [], highlighted: nil, mode: .conversion, context: "", emptyMessage: "", emptyDetail: "", geometry: RadialGeometry(count: 0)))
        super.init(frame: frameRect)
        // Existing local file URLs only. Receiving promised files needs a separate
        // asynchronous import pipeline, which this destination does not implement.
        registerForDraggedTypes([.fileURL, NSPasteboard.PasteboardType("com.apple.finder.node")])
        wantsLayer = true
        host.sizingOptions = []
        addSubview(host)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Yuzu radial menu")
    }

    required init?(coder: NSCoder) { fatalError("Not supported") }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    override func layout() {
        super.layout()
        host.frame = NSRect(x: center.x - discRadius, y: center.y - discRadius, width: discRadius * 2, height: discRadius * 2)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // This is a compact window. Its whole content is the destination, including
        // the hub and gaps, so AppKit continues sending drag updates between wedges.
        bounds.contains(point) ? self : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    func configure(content: RadialContent, mode: RadialMode) {
        updatingPresentation = true
        clearHighlight()
        self.mode = mode
        items = content.items
        context = content.context
        fileName = content.fileName
        emptyMessage = content.emptyMessage
        emptyDetail = content.emptyDetail
        updatingPresentation = false
        refresh()
    }

    func reset() {
        onSelect = nil
        onCancel = nil
        onDragUpdate = nil
        onDrop = nil
        onPrepareDrop = nil
        onDragEnd = nil
        onHoverChanged = nil
        nativeDragAllowed = nil
        updatingPresentation = true
        interactive = false
        configure(content: RadialContent(items: [], emptyMessage: "", emptyDetail: "", context: "", fileName: nil), mode: .conversion)
    }

    private func refresh() {
        guard !updatingPresentation else { return }
        host.rootView = RadialWheelView(
            items: items,
            highlighted: highlighted,
            mode: mode,
            context: context,
            fileName: fileName,
            isDragging: !interactive,
            emptyMessage: emptyMessage,
            emptyDetail: emptyDetail,
            geometry: geometry
        )
        setAccessibilityValue(highlighted.flatMap { items.indices.contains($0) ? items[$0].detail : nil } ?? mode.title)
    }

    func index(at point: NSPoint) -> Int? {
        // NSView is y-up, SwiftUI Path is y-down. Flip once around the fixed hub.
        geometry.index(at: CGPoint(x: point.x - center.x, y: center.y - point.y))
    }

    func updateHighlight(forWindowPoint point: NSPoint) {
        let local = convert(point, from: nil)
        highlighted = nativeDragAllowed == false ? nil : index(at: local)
        if DragDebug.enabled, Date().timeIntervalSince(lastCoordinateLog) >= 0.25 {
            lastCoordinateLog = Date()
            let screen = window?.convertPoint(toScreen: point) ?? .zero
            DragDebug.log("hit test screen=\(screen) window=\(point) local=\(local) center=\(center) wedge=\(highlighted.map(String.init) ?? "none")")
        }
    }

    func updateHighlight(forScreenPoint point: NSPoint) {
        guard let window else { return }
        updateHighlight(forWindowPoint: window.convertPoint(fromScreen: point))
    }

    override func wantsPeriodicDraggingUpdates() -> Bool { true }

    private func updateDrag(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !interactive, onDragUpdate?(sender) == true else {
            nativeDragAllowed = false
            clearHighlight()
            return []
        }
        // Never negotiate move: Finder must not delete the source after conversion.
        let mask = sender.draggingSourceOperationMask
        let operation: NSDragOperation = mask.contains(.copy) ? .copy : (mask.contains(.generic) ? .generic : [])
        nativeDragAllowed = !operation.isEmpty
        updateHighlight(forWindowPoint: sender.draggingLocation)
        return highlighted == nil ? [] : operation
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        DragDebug.log("native draggingEntered sequence=\(sender.draggingSequenceNumber) mask=\(sender.draggingSourceOperationMask.rawValue)")
        return updateDrag(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateDrag(sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let accepted = !updateDrag(sender).isEmpty && (onPrepareDrop?(sender) ?? false)
        DragDebug.log("prepare drop sequence=\(sender.draggingSequenceNumber) accepted=\(accepted)")
        return accepted
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        DragDebug.log("native draggingExited")
        nativeDragAllowed = nil
        clearHighlight()
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        DragDebug.log("native draggingEnded sequence=\(sender.draggingSequenceNumber)")
        onDragEnd?(sender)
        nativeDragAllowed = nil
        clearHighlight()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard !updateDrag(sender).isEmpty else { return false }
        let accepted = onDrop?(sender) ?? false
        DragDebug.log("perform drop sequence=\(sender.draggingSequenceNumber) accepted=\(accepted)")
        return accepted
    }

    override func mouseMoved(with event: NSEvent) {
        guard interactive else { return }
        updateHighlight(forWindowPoint: event.locationInWindow)
    }

    override func mouseDown(with event: NSEvent) {
        guard interactive else { return }
        updateHighlight(forWindowPoint: event.locationInWindow)
        if let highlighted, items.indices.contains(highlighted) { onSelect?(items[highlighted]) } else { onCancel?() }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancel?()
            return
        }
        guard interactive else { return }
        switch event.keyCode {
        case 36, 76:
            if let highlighted, items.indices.contains(highlighted) { onSelect?(items[highlighted]) }
        case 123, 126: step(-1)
        case 124, 125: step(1)
        default: super.keyDown(with: event)
        }
    }

    private func step(_ delta: Int) {
        guard !items.isEmpty else { return }
        let current = highlighted ?? (delta < 0 ? 0 : -1)
        highlighted = (current + delta + items.count) % items.count
    }

    func clearHighlight() { highlighted = nil }

    func highlight(_ index: Int) { highlighted = items.indices.contains(index) ? index : nil }
}
