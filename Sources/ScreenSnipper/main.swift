import AppKit
import AVFoundation
import Carbon
import CoreGraphics
import Darwin
import Foundation
import ScreenSnipperCore
import ImageIO
import UniformTypeIdentifiers

enum SelectionPreferences {
    private static let xKey = "selectionRect.x"
    private static let yKey = "selectionRect.y"
    private static let widthKey = "selectionRect.width"
    private static let heightKey = "selectionRect.height"

    static func load() -> CGRect? {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: widthKey) != nil,
              defaults.object(forKey: heightKey) != nil
        else {
            return nil
        }

        let rect = CGRect(
            x: defaults.double(forKey: xKey),
            y: defaults.double(forKey: yKey),
            width: defaults.double(forKey: widthKey),
            height: defaults.double(forKey: heightKey)
        )

        guard rect.width >= 24,
              rect.height >= 24,
              SelectionPlacement.isReachable(rect, onScreens: NSScreen.screens.map(\.frame))
        else {
            return nil
        }
        return rect
    }

    static func save(_ rect: CGRect) {
        let defaults = UserDefaults.standard
        defaults.set(rect.origin.x, forKey: xKey)
        defaults.set(rect.origin.y, forKey: yKey)
        defaults.set(rect.width, forKey: widthKey)
        defaults.set(rect.height, forKey: heightKey)
    }
}

private struct SelectionResizeEdges: OptionSet {
    let rawValue: Int

    static let minX = SelectionResizeEdges(rawValue: 1 << 0)
    static let maxX = SelectionResizeEdges(rawValue: 1 << 1)
    static let minY = SelectionResizeEdges(rawValue: 1 << 2)
    static let maxY = SelectionResizeEdges(rawValue: 1 << 3)
}

enum HotKeyError: Error, CustomStringConvertible {
    case installHandlerFailed(OSStatus)
    case registerFailed(OSStatus)

    var description: String {
        switch self {
        case .installHandlerFailed(let status):
            "event handler install failed with status \(status)"
        case .registerFailed(let status):
            "hotkey registration failed with status \(status)"
        }
    }
}

enum ToggleController {
    private static var pidURL: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("screen-snipper.pid")
    }

    static func closeRunningInstanceIfNeeded() -> Bool {
        guard let pid = runningPID() else {
            return false
        }

        if kill(pid, SIGUSR1) == 0 {
            return true
        }

        try? FileManager.default.removeItem(at: pidURL)
        return false
    }

    static func registerCurrentProcess() {
        let pid = String(getpid())
        try? pid.write(to: pidURL, atomically: true, encoding: .utf8)
    }

    static func unregisterCurrentProcess() {
        guard let pid = runningPID(), pid == getpid() else {
            return
        }
        try? FileManager.default.removeItem(at: pidURL)
    }

    private static func runningPID() -> pid_t? {
        guard let contents = try? String(contentsOf: pidURL, encoding: .utf8),
              let pid = pid_t(contents.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 0
        else {
            return nil
        }

        if kill(pid, 0) == 0 {
            return pid
        }

        try? FileManager.default.removeItem(at: pidURL)
        return nil
    }
}

final class AppHotKeys: @unchecked Sendable {
    private var hotKeyRefs: [EventHotKeyRef] = []
    private var handlerRef: EventHandlerRef?
    private let dispatcher: AppShortcutDispatcher

    init(
        record: @escaping @Sendable () -> Void,
        close: @escaping @Sendable () -> Void,
        moveScreen: @escaping @Sendable () -> Void
    ) throws {
        dispatcher = AppShortcutDispatcher(
            record: { OperationQueue.main.addOperation(record) },
            close: { OperationQueue.main.addOperation(close) },
            moveScreen: { OperationQueue.main.addOperation(moveScreen) }
        )
        try install()
    }

    deinit {
        for hotKeyRef in hotKeyRefs {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let handlerRef {
            RemoveEventHandler(handlerRef)
        }
    }

    private func install() throws {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        var handlerRef: EventHandlerRef?
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }

                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                let hotKeys = Unmanaged<AppHotKeys>.fromOpaque(userData).takeUnretainedValue()
                guard status == noErr, hotKeys.dispatcher.dispatch(id: hotKeyID.id) else {
                    return OSStatus(eventNotHandledErr)
                }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )
        guard installStatus == noErr else {
            throw HotKeyError.installHandlerFailed(installStatus)
        }
        self.handlerRef = handlerRef
        try AppShortcutRegistrationPlan().registerAll(
            register: { shortcut in
                try register(id: shortcut, keyCode: keyCode(for: shortcut))
            },
            reportOptionalFailure: { shortcut, error in
                fputs("screen-snipper: \(shortcut.name) keyboard shortcut unavailable: \(error)\n", stderr)
            }
        )
    }

    private func register(id: AppShortcut, keyCode: UInt32) throws {
        let hotKeyID = EventHotKeyID(signature: fourCharCode("GSNP"), id: id.rawValue)
        var hotKeyRef: EventHotKeyRef?
        let registerStatus = RegisterEventHotKey(
            keyCode,
            UInt32(cmdKey | shiftKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        guard registerStatus == noErr else {
            throw HotKeyError.registerFailed(registerStatus)
        }
        if let hotKeyRef {
            hotKeyRefs.append(hotKeyRef)
        }
    }

    private func keyCode(for shortcut: AppShortcut) -> UInt32 {
        switch shortcut {
        case .record:
            UInt32(kVK_Space)
        case .close:
            26
        case .moveScreen:
            UInt32(kVK_ANSI_M)
        }
    }

    private func fourCharCode(_ string: String) -> OSType {
        string.utf8.reduce(0) { result, character in
            (result << 8) + OSType(character)
        }
    }
}

private extension AppShortcut {
    var name: String {
        switch self {
        case .record: "record"
        case .close: "close"
        case .moveScreen: "move screen"
        }
    }
}

@MainActor
final class SelectionView: NSView {
    var selectionRect: CGRect? {
        didSet {
            needsDisplay = true
            if let window {
                window.invalidateCursorRects(for: self)
            }
        }
    }
    var onSelectionChange: ((CGRect) -> Void)?

    private enum DragOperation {
        case create(start: NSPoint)
        case move(start: NSPoint, original: CGRect)
        case resize(start: NSPoint, original: CGRect, edges: ResizeEdges)
    }

    private struct ResizeEdges: OptionSet {
        let rawValue: Int

        static let minX = ResizeEdges(rawValue: 1 << 0)
        static let maxX = ResizeEdges(rawValue: 1 << 1)
        static let minY = ResizeEdges(rawValue: 1 << 2)
        static let maxY = ResizeEdges(rawValue: 1 << 3)
    }

    private let minimumSelectionSize: CGFloat = 24
    private let handleHitSize: CGFloat = 10
    private let borderHitSize: CGFloat = 8
    private var dragOperation: DragOperation?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        window?.makeFirstResponder(self)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.08).setFill()
        bounds.fill()

        guard let selectionRect = localSelectionRect, !selectionRect.isEmpty else { return }

        NSColor.clear.setFill()
        selectionRect.fill(using: .clear)

        NSColor.systemBlue.setStroke()
        let path = NSBezierPath(rect: selectionRect)
        path.lineWidth = 2
        path.stroke()

        NSColor.systemBlue.withAlphaComponent(0.12).setFill()
        selectionRect.fill()

        NSColor.systemBlue.setFill()
        for handle in handleRects(for: selectionRect) {
            NSBezierPath(roundedRect: handle, xRadius: 3, yRadius: 3).fill()
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard interactionKind(at: point) != nil else {
            return nil
        }
        return self
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard let rect = localSelectionRect else { return }

        for borderRect in borderHitRects(for: rect) {
            addCursorRect(borderRect, cursor: .openHand)
        }

        for handle in handleHitRects(for: rect) {
            addCursorRect(handle.rect, cursor: cursor(for: handle.edges))
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let selectionRect = localSelectionRect else {
            dragOperation = .create(start: point)
            updateSelection(from: point, to: point)
            return
        }

        if let edges = resizeHandleEdges(at: point, in: selectionRect) {
            cursor(for: edges).set()
            dragOperation = .resize(start: point, original: selectionRect, edges: edges)
        } else if isBorderHit(at: point, in: selectionRect) {
            NSCursor.closedHand.set()
            dragOperation = .move(start: point, original: selectionRect)
        } else {
            dragOperation = nil
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragOperation else { return }
        let point = convert(event.locationInWindow, from: nil)

        switch dragOperation {
        case .create(let start):
            updateSelection(from: start, to: point)
        case .move(let start, let original):
            let delta = NSPoint(x: point.x - start.x, y: point.y - start.y)
            updateGlobalSelection(original.offsetBy(dx: delta.x, dy: delta.y))
        case .resize(let start, let original, let edges):
            let delta = NSPoint(x: point.x - start.x, y: point.y - start.y)
            updateGlobalSelection(resized(original, delta: delta, edges: edges))
        }
    }

    override func mouseUp(with event: NSEvent) {
        dragOperation = nil
        NSCursor.arrow.set()
    }

    private var localSelectionRect: CGRect? {
        guard let selectionRect, let window else { return nil }
        let windowRect = window.convertFromScreen(selectionRect)
        return convert(windowRect, from: nil)
    }

    private func updateSelection(from start: NSPoint, to end: NSPoint) {
        updateGlobalSelection(
            CGRect(
                x: min(start.x, end.x),
                y: min(start.y, end.y),
                width: abs(start.x - end.x),
                height: abs(start.y - end.y)
            )
        )
    }

    private func updateGlobalSelection(_ localRect: CGRect) {
        guard let window else { return }
        let normalized = normalized(localRect)
        guard normalized.width >= minimumSelectionSize, normalized.height >= minimumSelectionSize else {
            return
        }

        let windowRect = convert(normalized, to: nil)
        let globalRect = window.convertToScreen(windowRect)
        onSelectionChange?(globalRect)
    }

    private func normalized(_ rect: CGRect) -> CGRect {
        CGRect(
            x: min(rect.minX, rect.maxX),
            y: min(rect.minY, rect.maxY),
            width: abs(rect.width),
            height: abs(rect.height)
        )
    }

    private func resized(_ rect: CGRect, delta: NSPoint, edges: ResizeEdges) -> CGRect {
        var minX = rect.minX
        var maxX = rect.maxX
        var minY = rect.minY
        var maxY = rect.maxY

        if edges.contains(.minX) { minX += delta.x }
        if edges.contains(.maxX) { maxX += delta.x }
        if edges.contains(.minY) { minY += delta.y }
        if edges.contains(.maxY) { maxY += delta.y }

        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func resizeHandleEdges(at point: NSPoint, in rect: CGRect) -> ResizeEdges? {
        handleHitRects(for: rect).first { $0.rect.contains(point) }?.edges
    }

    private func interactionKind(at point: NSPoint) -> DragOperation? {
        guard let rect = localSelectionRect else { return nil }
        if let edges = resizeHandleEdges(at: point, in: rect) {
            return .resize(start: point, original: rect, edges: edges)
        }
        if isBorderHit(at: point, in: rect) {
            return .move(start: point, original: rect)
        }
        return nil
    }

    private func isBorderHit(at point: NSPoint, in rect: CGRect) -> Bool {
        let outer = rect.insetBy(dx: -borderHitSize, dy: -borderHitSize)
        let inner = rect.insetBy(dx: borderHitSize, dy: borderHitSize)
        return outer.contains(point) && !inner.contains(point)
    }

    private func borderHitRects(for rect: CGRect) -> [CGRect] {
        [
            CGRect(x: rect.minX - borderHitSize, y: rect.minY - borderHitSize, width: rect.width + borderHitSize * 2, height: borderHitSize * 2),
            CGRect(x: rect.minX - borderHitSize, y: rect.maxY - borderHitSize, width: rect.width + borderHitSize * 2, height: borderHitSize * 2),
            CGRect(x: rect.minX - borderHitSize, y: rect.minY + borderHitSize, width: borderHitSize * 2, height: max(0, rect.height - borderHitSize * 2)),
            CGRect(x: rect.maxX - borderHitSize, y: rect.minY + borderHitSize, width: borderHitSize * 2, height: max(0, rect.height - borderHitSize * 2))
        ]
    }

    private func handleRects(for rect: CGRect) -> [CGRect] {
        let size: CGFloat = 8
        return handleRects(for: rect, size: size).map(\.rect)
    }

    private func handleHitRects(for rect: CGRect) -> [(rect: CGRect, edges: ResizeEdges)] {
        handleRects(for: rect, size: handleHitSize * 2)
    }

    private func handleRects(for rect: CGRect, size: CGFloat) -> [(rect: CGRect, edges: ResizeEdges)] {
        let xValues = [rect.minX, rect.midX, rect.maxX]
        let yValues = [rect.minY, rect.midY, rect.maxY]

        return xValues.flatMap { x in
            yValues.compactMap { y in
                let edges = resizeEdges(forHandleAt: NSPoint(x: x, y: y), in: rect)
                guard !edges.isEmpty else { return nil }
                return (
                    rect: CGRect(x: x - size / 2, y: y - size / 2, width: size, height: size),
                    edges: edges
                )
            }
        }
    }

    private func resizeEdges(forHandleAt point: NSPoint, in rect: CGRect) -> ResizeEdges {
        var edges: ResizeEdges = []

        if point.x == rect.minX { edges.insert(.minX) }
        if point.x == rect.maxX { edges.insert(.maxX) }
        if point.y == rect.minY { edges.insert(.minY) }
        if point.y == rect.maxY { edges.insert(.maxY) }

        return edges
    }

    private func cursor(for edges: ResizeEdges) -> NSCursor {
        if edges.contains(.minX) || edges.contains(.maxX) {
            return .resizeLeftRight
        }
        if edges.contains(.minY) || edges.contains(.maxY) {
            return .resizeUpDown
        }
        return .crosshair
    }
}

@MainActor
private final class SelectionInteractionView: NSView {
    enum Operation {
        case move
        case resize(SelectionResizeEdges)
    }

    var operation: Operation = .move
    var currentSelection: (() -> CGRect?)?
    var updateSelection: ((CGRect) -> Void)?

    private let minimumSelectionSize: CGFloat = 24
    private var dragStartPoint: NSPoint?
    private var originalRect: CGRect?

    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: cursor)
    }

    override func mouseDown(with event: NSEvent) {
        dragStartPoint = screenPoint(for: event)
        originalRect = currentSelection?()
        cursor.set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStartPoint, let originalRect else { return }
        let point = screenPoint(for: event)
        let delta = NSPoint(x: point.x - dragStartPoint.x, y: point.y - dragStartPoint.y)

        switch operation {
        case .move:
            updateSelection?(originalRect.offsetBy(dx: delta.x, dy: delta.y).integral)
        case .resize(let edges):
            updateSelection?(resized(originalRect, delta: delta, edges: edges).integral)
        }
    }

    override func mouseUp(with event: NSEvent) {
        dragStartPoint = nil
        originalRect = nil
        NSCursor.arrow.set()
    }

    private var cursor: NSCursor {
        switch operation {
        case .move:
            .openHand
        case .resize(let edges):
            if edges.contains(.minX) || edges.contains(.maxX) {
                .resizeLeftRight
            } else {
                .resizeUpDown
            }
        }
    }

    private func screenPoint(for event: NSEvent) -> NSPoint {
        guard let window else { return .zero }
        let rect = NSRect(origin: event.locationInWindow, size: .zero)
        return window.convertToScreen(rect).origin
    }

    private func resized(_ rect: CGRect, delta: NSPoint, edges: SelectionResizeEdges) -> CGRect {
        var minX = rect.minX
        var maxX = rect.maxX
        var minY = rect.minY
        var maxY = rect.maxY

        if edges.contains(.minX) { minX += delta.x }
        if edges.contains(.maxX) { maxX += delta.x }
        if edges.contains(.minY) { minY += delta.y }
        if edges.contains(.maxY) { maxY += delta.y }

        if maxX - minX < minimumSelectionSize {
            if edges.contains(.minX) {
                minX = maxX - minimumSelectionSize
            } else {
                maxX = minX + minimumSelectionSize
            }
        }

        if maxY - minY < minimumSelectionSize {
            if edges.contains(.minY) {
                minY = maxY - minimumSelectionSize
            } else {
                maxY = minY + minimumSelectionSize
            }
        }

        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

@MainActor
final class SelectionController {
    private var windows: [NSWindow] = []
    private var interactionWindows: [NSWindow] = []
    private var screenObserver: NSObjectProtocol?
    private(set) var selectionRect: CGRect? = SelectionPreferences.load() {
        didSet {
            windows.compactMap { $0.contentView as? SelectionView }.forEach { view in
                view.selectionRect = selectionRect
            }
            syncInteractionWindows()
            if let selectionRect {
                SelectionPreferences.save(selectionRect)
            }
        }
    }

    init() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.screensDidChange()
            }
        }
    }

    func show() {
        if windows.isEmpty {
            makeWindows()
        }
        if selectionRect == nil {
            selectionRect = defaultSelectionRect()
        }
        windows.forEach { $0.orderFrontRegardless() }
        syncInteractionWindows()
        NSApp.activate(ignoringOtherApps: true)
    }

    func hide() {
        NSCursor.arrow.set()
        windows.forEach { $0.orderOut(nil) }
        interactionWindows.forEach { $0.orderOut(nil) }
    }

    private func makeWindows() {
        for screen in NSScreen.screens {
            let view = SelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.selectionRect = selectionRect
            view.onSelectionChange = { [weak self] rect in
                self?.applySelection(rect)
            }

            let window = NSWindow(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
            window.backgroundColor = .clear
            window.isOpaque = false
            window.ignoresMouseEvents = true
            window.sharingType = .none
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.contentView = view
            windows.append(window)
        }
    }

    private func syncInteractionWindows() {
        guard let selectionRect else { return }
        let items = interactionRects(for: selectionRect)

        if interactionWindows.count != items.count {
            rebuildInteractionWindows(items: items)
            return
        }

        for (window, item) in zip(interactionWindows, items) {
            window.setFrame(item.rect, display: true)
            if let view = window.contentView as? SelectionInteractionView {
                view.frame = NSRect(origin: .zero, size: item.rect.size)
                view.operation = item.operation
                window.invalidateCursorRects(for: view)
            }
            window.orderFrontRegardless()
        }
    }

    private func rebuildInteractionWindows(items: [(rect: CGRect, operation: SelectionInteractionView.Operation)]) {
        interactionWindows.forEach { $0.orderOut(nil) }
        interactionWindows.removeAll()

        for item in items {
            let view = SelectionInteractionView(frame: NSRect(origin: .zero, size: item.rect.size))
            view.operation = item.operation
            view.currentSelection = { [weak self] in self?.selectionRect }
            view.updateSelection = { [weak self] rect in self?.applySelection(rect) }

            let window = NSWindow(
                contentRect: item.rect,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.level = .floating
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = false
            window.ignoresMouseEvents = false
            window.sharingType = .none
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.contentView = view
            window.orderFrontRegardless()
            interactionWindows.append(window)
        }
    }

    private func interactionRects(for rect: CGRect) -> [(rect: CGRect, operation: SelectionInteractionView.Operation)] {
        let border: CGFloat = 8
        let handle: CGFloat = 20

        let borderRects: [(CGRect, SelectionInteractionView.Operation)] = [
            (CGRect(x: rect.minX - border, y: rect.minY - border, width: rect.width + border * 2, height: border * 2), .move),
            (CGRect(x: rect.minX - border, y: rect.maxY - border, width: rect.width + border * 2, height: border * 2), .move),
            (CGRect(x: rect.minX - border, y: rect.minY + border, width: border * 2, height: max(0, rect.height - border * 2)), .move),
            (CGRect(x: rect.maxX - border, y: rect.minY + border, width: border * 2, height: max(0, rect.height - border * 2)), .move)
        ]

        let handleRects = handleItems(for: rect, size: handle).map { item in
            (item.rect, SelectionInteractionView.Operation.resize(item.edges))
        }

        return borderRects + handleRects
    }

    private func handleItems(for rect: CGRect, size: CGFloat) -> [(rect: CGRect, edges: SelectionResizeEdges)] {
        let xValues = [rect.minX, rect.midX, rect.maxX]
        let yValues = [rect.minY, rect.midY, rect.maxY]

        return xValues.flatMap { x in
            yValues.compactMap { y in
                let edges = resizeEdges(forHandleAt: NSPoint(x: x, y: y), in: rect)
                guard !edges.isEmpty else { return nil }
                return (
                    rect: CGRect(x: x - size / 2, y: y - size / 2, width: size, height: size).integral,
                    edges: edges
                )
            }
        }
    }

    private func resizeEdges(forHandleAt point: NSPoint, in rect: CGRect) -> SelectionResizeEdges {
        var edges: SelectionResizeEdges = []

        if point.x == rect.minX { edges.insert(.minX) }
        if point.x == rect.maxX { edges.insert(.maxX) }
        if point.y == rect.minY { edges.insert(.minY) }
        if point.y == rect.maxY { edges.insert(.maxY) }

        return edges
    }

    /// Jumps the selection to the next display, cycling left to right. The rect
    /// keeps its size where it fits and lands at the same relative position
    /// within the target's visible frame, clear of the menu bar and Dock.
    func moveToNextScreen() {
        guard let selectionRect, NSScreen.screens.count > 1 else { return }

        let screens = NSScreen.screens.sorted { first, second in
            if first.frame.minX != second.frame.minX {
                return first.frame.minX < second.frame.minX
            }
            return first.frame.minY < second.frame.minY
        }
        guard let current = NSScreen.screen(containingLargestAreaOf: selectionRect),
              let index = screens.firstIndex(of: current)
        else {
            return
        }

        let target = screens[(index + 1) % screens.count]
        self.selectionRect = SelectionPlacement.moved(
            selectionRect,
            from: current.visibleFrame,
            to: target.visibleFrame
        )
    }

    /// Expands the selection to cover the entire display it currently occupies.
    func fillCurrentScreen() {
        guard let selectionRect,
              let screen = NSScreen.screen(containingLargestAreaOf: selectionRect)
        else {
            return
        }
        self.selectionRect = screen.frame.integral
    }

    /// Drops updates that would strand the selection where no screen shows enough
    /// of it to grab: gaps in the display arrangement, or past the far edge of a
    /// smaller monitor. Moves compute the rect from the drag's absolute delta, so
    /// the selection catches up as soon as the cursor carries it back over a screen.
    private func applySelection(_ rect: CGRect) {
        guard SelectionPlacement.isReachable(rect, onScreens: NSScreen.screens.map(\.frame)) else {
            return
        }
        selectionRect = rect
    }

    private func screensDidChange() {
        let wasVisible = windows.contains { $0.isVisible }
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()

        if let selectionRect,
           !SelectionPlacement.isReachable(selectionRect, onScreens: NSScreen.screens.map(\.frame)) {
            self.selectionRect = defaultSelectionRect()
        }

        if wasVisible {
            show()
        }
    }

    private func defaultSelectionRect() -> CGRect {
        let frame = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 960, height: 540)
        let width = min(frame.width * 0.6, 900)
        let height = min(frame.height * 0.55, 560)
        return CGRect(
            x: frame.midX - width / 2,
            y: frame.midY - height / 2,
            width: width,
            height: height
        ).integral
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let options: Options
    private let toolbar: CaptureToolbarController
    private let selector = SelectionController()
    private var keyboardShortcutMonitor: Any?
    private var hotKeys: AppHotKeys?
    private var recordingTask: Task<Void, Never>?
    private var toggleQuitSignal: DispatchSourceSignal?
    private var stopSignal: RecordingStopSignal?

    init(options: Options) {
        self.options = options
        toolbar = CaptureToolbarController(options: options)
    }

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        ToggleController.registerCurrentProcess()
        signal(SIGUSR1, SIG_IGN)
        let toggleQuitSignal = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        toggleQuitSignal.setEventHandler { [weak self] in
            self?.cancel()
        }
        toggleQuitSignal.resume()
        self.toggleQuitSignal = toggleQuitSignal

        selector.show()
        keyboardShortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if Self.isLauncherShortcut(event) {
                self?.cancel()
                return nil
            }

            if Self.isRecordShortcut(event) {
                self?.toolbar.toggleRecordingFromShortcut()
                return nil
            }

            if Self.isMoveScreenShortcut(event) {
                self?.selector.moveToNextScreen()
                return nil
            }

            return event
        }

        do {
            hotKeys = try AppHotKeys(
                record: { [weak self] in
                    Task { @MainActor in
                        self?.toolbar.toggleRecordingFromShortcut()
                    }
                },
                close: { [weak self] in
                    Task { @MainActor in
                        self?.cancel()
                    }
                },
                moveScreen: { [weak self] in
                    Task { @MainActor in
                        self?.selector.moveToNextScreen()
                    }
                }
            )
        } catch {
            fputs("screen-snipper: could not register keyboard shortcuts: \(error)\n", stderr)
        }

        toolbar.begin(
            recordToggle: { [weak self] toolbarSelection in
                self?.toggleRecording(toolbarSelection: toolbarSelection)
            },
            cancel: { [weak self] in
                self?.cancel()
            },
            moveScreen: { [weak self] in
                self?.selector.moveToNextScreen()
            },
            fillScreen: { [weak self] in
                self?.selector.fillCurrentScreen()
            }
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        ToggleController.unregisterCurrentProcess()
        toggleQuitSignal?.cancel()
        if let keyboardShortcutMonitor {
            NSEvent.removeMonitor(keyboardShortcutMonitor)
        }
        hotKeys = nil
    }

    private static func isLauncherShortcut(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return flags == [.command, .shift] && event.keyCode == 26
    }

    private static func isRecordShortcut(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return flags == [.command, .shift] && event.keyCode == UInt16(kVK_Space)
    }

    private static func isMoveScreenShortcut(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return flags == [.command, .shift] && event.keyCode == UInt16(kVK_ANSI_M)
    }

    private func toggleRecording(toolbarSelection: CaptureToolbarSelection) {
        if let stopSignal {
            Task {
                await stopSignal.stop()
            }
            return
        }

        startRecording(toolbarSelection: toolbarSelection)
    }

    private func startRecording(toolbarSelection: CaptureToolbarSelection) {
        guard let selectionRect = selector.selectionRect else {
            fail(ScreenSnipperError.selectionCancelled)
            return
        }

        let stopSignal = RecordingStopSignal()
        self.stopSignal = stopSignal
        toolbar.setRecording(true)

        recordingTask = Task {
            do {
                try Permissions.ensureScreenRecording()

                let outputURL = try self.outputURL(toolbarSelection: toolbarSelection)
                let delay = 1 / toolbarSelection.fps
                let region = try CaptureRegion(selectionRect: selectionRect)
                if self.options.debug {
                    fputs("\(region.debugDescription)\n", stderr)
                }

                try await Task.sleep(nanoseconds: 150_000_000)

                switch toolbarSelection.format {
                case .gif:
                    try await GifRecorder.record(
                        region: region,
                        delay: delay,
                        maxWidth: toolbarSelection.maxWidth,
                        outputURL: outputURL,
                        stopSignal: stopSignal
                    )
                case .video:
                    try await VideoRecorder.record(
                        region: region,
                        frameDuration: delay,
                        maxWidth: toolbarSelection.maxWidth,
                        outputURL: outputURL,
                        stopSignal: stopSignal
                    )
                }

                let shouldCopy = self.shouldCopyToClipboard(toolbarSelection: toolbarSelection)
                let shouldSave = self.shouldSaveFile(toolbarSelection: toolbarSelection)
                if shouldCopy {
                    try Clipboard.copyRecording(from: outputURL, format: toolbarSelection.format)
                }

                // A clipboard-only recording still needs its file on disk: pasting a
                // movie hands the receiving app a file URL, not the bytes.
                if !shouldSave, !shouldCopy {
                    try? FileManager.default.removeItem(at: outputURL)
                }

                print(self.successMessage(outputURL: outputURL, saveFile: shouldSave, copyToClipboard: shouldCopy))
                self.finishRecording()
            } catch {
                self.finishRecording()
                fputs("screen-snipper: \(error)\n", stderr)
            }
        }
    }

    private func finishRecording() {
        stopSignal = nil
        recordingTask = nil
        toolbar.setRecording(false)
    }

    private func cancel() {
        if let stopSignal {
            Task {
                await stopSignal.stop()
            }
        }
        selector.hide()
        NSApp.terminate(nil)
    }

    private func outputURL(toolbarSelection: CaptureToolbarSelection) throws -> URL {
        if let output = options.output {
            return output
        }

        let outputURL: URL
        if shouldSaveFile(toolbarSelection: toolbarSelection) {
            outputURL = defaultOutputURL(
                date: Date(),
                baseDirectory: toolbarSelection.folderURL,
                folderName: nil,
                fileExtension: toolbarSelection.format.fileExtension
            )
        } else {
            outputURL = clipboardTempURL(
                date: Date(),
                fileExtension: toolbarSelection.format.fileExtension
            )
        }
        let outputDirectory = outputURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        return outputURL
    }

    private func shouldSaveFile(toolbarSelection: CaptureToolbarSelection) -> Bool {
        options.saveFile && toolbarSelection.saveToFolder
    }

    private func shouldCopyToClipboard(toolbarSelection: CaptureToolbarSelection) -> Bool {
        options.copyToClipboard || toolbarSelection.copyToClipboard
    }

    private func successMessage(outputURL: URL, saveFile: Bool, copyToClipboard: Bool) -> String {
        switch (saveFile, copyToClipboard) {
        case (true, true):
            "Saved \(outputURL.path) and copied it to the clipboard"
        case (true, false):
            "Saved \(outputURL.path)"
        case (false, true):
            "Copied \(outputURL.path) to the clipboard"
        case (false, false):
            "Done"
        }
    }

    private func fail(_ error: Error) {
        fputs("screen-snipper: \(error)\n", stderr)
        NSApp.terminate(nil)
    }
}

struct CaptureRegion {
    let displayID: CGDirectDisplayID
    let selectionRect: CGRect
    let screenFrame: CGRect
    let displayBounds: CGRect
    let displayRect: CGRect

    init(selectionRect: CGRect) throws {
        guard let screen = NSScreen.screen(containingLargestAreaOf: selectionRect),
              let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        else {
            throw ScreenSnipperError.displayNotFound(selectionRect)
        }

        let clippedRect = selectionRect.intersection(screen.frame)
        let displayBounds = CGDisplayBounds(displayID)
        let mainDisplayBounds = CGDisplayBounds(CGMainDisplayID())
        let flippedGlobalY = mainDisplayBounds.height - clippedRect.maxY

        self.displayID = displayID
        self.selectionRect = selectionRect
        self.screenFrame = screen.frame
        self.displayBounds = displayBounds
        self.displayRect = CGRect(
            x: clippedRect.minX - displayBounds.minX,
            y: flippedGlobalY - displayBounds.minY,
            width: clippedRect.width,
            height: clippedRect.height
        ).integral
    }

    var debugDescription: String {
        """
        selectionRect: \(selectionRect)
        screenFrame: \(screenFrame)
        displayID: \(displayID)
        displayBounds: \(displayBounds)
        displayRect: \(displayRect)
        """
    }
}

extension NSScreen {
    static func screen(containingLargestAreaOf rect: CGRect) -> NSScreen? {
        screens.max { first, second in
            first.frame.intersection(rect).area < second.frame.intersection(rect).area
        }
    }
}

extension CGRect {
    var area: CGFloat {
        guard !isNull, !isEmpty else { return 0 }
        return width * height
    }
}

actor RecordingStopSignal {
    private var stopped = false

    func stop() {
        stopped = true
    }

    func isStopped() -> Bool {
        stopped
    }
}

enum GifRecorder {
    static func record(
        region: CaptureRegion,
        delay: TimeInterval,
        maxWidth: Int?,
        outputURL: URL,
        stopSignal: RecordingStopSignal
    ) async throws {
        let fileProperties = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFLoopCount: 0
            ]
        ] as CFDictionary

        let frameProperties = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: delay
            ]
        ] as CFDictionary

        var frames: [CGImage] = []
        while true {
            if await stopSignal.isStopped(), !frames.isEmpty {
                break
            }

            let targetTime = Date().addingTimeInterval(delay)

            guard let capturedImage = CGDisplayCreateImage(region.displayID, rect: region.displayRect) else {
                if frames.isEmpty {
                    throw ScreenSnipperError.captureFailed
                }
                continue
            }

            let image = resize(capturedImage, maxWidth: maxWidth) ?? capturedImage
            frames.append(image)

            let remaining = targetTime.timeIntervalSinceNow
            if remaining > 0 {
                try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            }
        }

        guard !frames.isEmpty else {
            throw ScreenSnipperError.noFramesCaptured
        }

        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL,
            UTType.gif.identifier as CFString,
            frames.count,
            nil
        ) else {
            throw ScreenSnipperError.gifDestinationFailed(outputURL)
        }

        CGImageDestinationSetProperties(destination, fileProperties)

        for image in frames {
            CGImageDestinationAddImage(destination, image, frameProperties)
        }

        if !CGImageDestinationFinalize(destination) {
            throw ScreenSnipperError.gifFinalizeFailed(outputURL)
        }
    }

    private static func resize(_ image: CGImage, maxWidth: Int?) -> CGImage? {
        guard let maxWidth, image.width > maxWidth else {
            return nil
        }

        let scale = CGFloat(maxWidth) / CGFloat(image.width)
        let width = maxWidth
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}

enum VideoRecorder {
    static func record(
        region: CaptureRegion,
        frameDuration: TimeInterval,
        maxWidth: Int?,
        outputURL: URL,
        stopSignal: RecordingStopSignal
    ) async throws {
        try? FileManager.default.removeItem(at: outputURL)

        guard let firstCapture = CGDisplayCreateImage(region.displayID, rect: region.displayRect) else {
            throw ScreenSnipperError.captureFailed
        }

        let firstImage = resize(firstCapture, maxWidth: maxWidth) ?? firstCapture
        let outputSize = evenSize(width: firstImage.width, height: firstImage.height)
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        } catch {
            throw ScreenSnipperError.videoDestinationFailed(outputURL)
        }

        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: outputSize.width,
                AVVideoHeightKey: outputSize.height
            ]
        )
        input.expectsMediaDataInRealTime = true

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: outputSize.width,
                kCVPixelBufferHeightKey as String: outputSize.height
            ]
        )

        guard writer.canAdd(input) else {
            throw ScreenSnipperError.videoDestinationFailed(outputURL)
        }
        writer.add(input)

        guard writer.startWriting() else {
            throw ScreenSnipperError.videoDestinationFailed(outputURL)
        }
        writer.startSession(atSourceTime: .zero)

        var frameIndex: Int64 = 0
        try append(firstImage, outputSize: outputSize, frameIndex: frameIndex, frameDuration: frameDuration, adaptor: adaptor, input: input, outputURL: outputURL)
        frameIndex += 1

        while true {
            if await stopSignal.isStopped(), frameIndex > 0 {
                break
            }

            let targetTime = Date().addingTimeInterval(frameDuration)

            guard let capturedImage = CGDisplayCreateImage(region.displayID, rect: region.displayRect) else {
                continue
            }

            let image = resize(capturedImage, maxWidth: maxWidth) ?? capturedImage
            try append(image, outputSize: outputSize, frameIndex: frameIndex, frameDuration: frameDuration, adaptor: adaptor, input: input, outputURL: outputURL)
            frameIndex += 1

            let remaining = targetTime.timeIntervalSinceNow
            if remaining > 0 {
                try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            }
        }

        input.markAsFinished()
        await writer.finishWriting()

        if writer.status != .completed {
            throw ScreenSnipperError.videoFinalizeFailed(outputURL)
        }
    }

    private static func append(
        _ image: CGImage,
        outputSize: (width: Int, height: Int),
        frameIndex: Int64,
        frameDuration: TimeInterval,
        adaptor: AVAssetWriterInputPixelBufferAdaptor,
        input: AVAssetWriterInput,
        outputURL: URL
    ) throws {
        while !input.isReadyForMoreMediaData {
            Thread.sleep(forTimeInterval: 0.002)
        }

        guard let pixelBuffer = pixelBuffer(from: image, outputSize: outputSize) else {
            throw ScreenSnipperError.videoFrameAppendFailed(outputURL)
        }

        let frameTime = CMTime(
            value: frameIndex,
            timescale: CMTimeScale(max(1, Int((1 / frameDuration).rounded())))
        )
        if !adaptor.append(pixelBuffer, withPresentationTime: frameTime) {
            throw ScreenSnipperError.videoFrameAppendFailed(outputURL)
        }
    }

    private static func pixelBuffer(from image: CGImage, outputSize: (width: Int, height: Int)) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            outputSize.width,
            outputSize.height,
            kCVPixelFormatType_32ARGB,
            [
                kCVPixelBufferCGImageCompatibilityKey: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey: true
            ] as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            return nil
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(pixelBuffer),
            width: outputSize.width,
            height: outputSize.height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        ) else {
            return nil
        }

        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: outputSize.width, height: outputSize.height))
        return pixelBuffer
    }

    private static func resize(_ image: CGImage, maxWidth: Int?) -> CGImage? {
        guard let maxWidth, image.width > maxWidth else {
            return nil
        }

        let scale = CGFloat(maxWidth) / CGFloat(image.width)
        let width = maxWidth
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private static func evenSize(width: Int, height: Int) -> (width: Int, height: Int) {
        (max(2, width - width % 2), max(2, height - height % 2))
    }
}

enum Permissions {
    static func ensureScreenRecording() throws {
        if CGPreflightScreenCaptureAccess() {
            return
        }

        if CGRequestScreenCaptureAccess() {
            return
        }

        throw ScreenSnipperError.screenRecordingPermissionDenied
    }
}

enum Clipboard {
    /// Puts a recording on the pasteboard.
    ///
    /// The file URL is what makes Cmd+V work: no app pastes raw `public.mpeg-4`
    /// bytes, they all read `public.file-url` (or a file promise) instead. GIF data
    /// is offered too so apps that inline images can take the bytes directly; MP4
    /// data is deliberately left off since nothing reads it and it can be large.
    static func copyRecording(from url: URL, format: RecordingFormat) throws {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        let item = NSPasteboardItem()
        if format == .gif {
            let data = try Data(contentsOf: url)
            item.setData(data, forType: NSPasteboard.PasteboardType(UTType.gif.identifier))
        }
        item.setString(url.absoluteString, forType: .fileURL)

        pasteboard.writeObjects([item])
    }
}

do {
    let options = try parseArguments(CommandLine.arguments)
    if options.toggle, ToggleController.closeRunningInstanceIfNeeded() {
        Foundation.exit(0)
    }

    let app = NSApplication.shared
    let delegate = AppDelegate(options: options)
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
} catch {
    fputs("screen-snipper: \(error)\n", stderr)
    Foundation.exit(1)
}
