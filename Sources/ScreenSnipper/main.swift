import AppKit
import AVFoundation
import Carbon
import CoreGraphics
import Darwin
import Foundation
import ScreenSnipperCore
import ImageIO
import ScreenCaptureKit
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

/// The displays the selection is snapped across. Stored as displays rather than a
/// rect so the selection follows them when the arrangement changes.
enum SpanPreferences {
    private static let displayIDsKey = "selectionSpan.displayIDs"

    static func load() -> [CGDirectDisplayID]? {
        guard let values = UserDefaults.standard.array(forKey: displayIDsKey) as? [Int], values.count >= 2 else {
            return nil
        }
        return values.map { CGDirectDisplayID($0) }
    }

    static func save(_ displayIDs: [CGDirectDisplayID]?) {
        if let displayIDs {
            UserDefaults.standard.set(displayIDs.map { Int($0) }, forKey: displayIDsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: displayIDsKey)
        }
    }
}

struct SpanChoice {
    let title: String
    let displayIDs: [CGDirectDisplayID]
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
        moveScreen: @escaping @Sendable () -> Void,
        spanScreens: @escaping @Sendable () -> Void
    ) throws {
        dispatcher = AppShortcutDispatcher(
            record: { OperationQueue.main.addOperation(record) },
            close: { OperationQueue.main.addOperation(close) },
            moveScreen: { OperationQueue.main.addOperation(moveScreen) },
            spanScreens: { OperationQueue.main.addOperation(spanScreens) }
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
        case .spanScreens:
            UInt32(kVK_ANSI_B)
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
        case .spanScreens: "span screens"
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
            // A snapped rect is not saved, so the stored one stays the free
            // selection to return to.
            if let selectionRect, spannedDisplayIDs == nil {
                SelectionPreferences.save(selectionRect)
            }
        }
    }
    private var spannedDisplayIDs: [CGDirectDisplayID]? = SpanPreferences.load()
    var onSpanChange: (() -> Void)?

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
        if spannedDisplayIDs != nil {
            resnapSpan()
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
        guard NSScreen.screens.count > 1 else { return }
        if spannedDisplayIDs != nil {
            endSpan()
        }
        guard let selectionRect else { return }

        let screens = orderedScreens()
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
        setSpannedDisplayIDs(nil)
        self.selectionRect = screen.frame.integral
    }

    /// The groups of monitors the selection can snap to, left to right.
    var spanChoices: [SpanChoice] {
        let screens = orderedScreens().compactMap { screen in
            screen.displayID.map { (screen: screen, displayID: $0) }
        }
        return SpanPlacement.choices(screens: screens.map { $0.screen.frame }).map { indices in
            let title: String
            if screens.count == 2 {
                title = "Both Monitors"
            } else if indices.count == screens.count {
                title = "All Monitors"
            } else {
                title = indices.map { screens[$0].screen.localizedName }.joined(separator: " + ")
            }
            return SpanChoice(title: title, displayIDs: indices.map { screens[$0].displayID })
        }
    }

    var activeSpanIndex: Int? {
        guard let spannedDisplayIDs else { return nil }
        return spanChoices.firstIndex { Set($0.displayIDs) == Set(spannedDisplayIDs) }
    }

    /// Steps through the span choices and then back to the free selection. With
    /// two monitors that is a plain on/off toggle.
    func cycleSpan() {
        let choices = spanChoices
        guard !choices.isEmpty else { return }

        guard let active = activeSpanIndex else {
            span(choices[0])
            return
        }
        if active + 1 < choices.count {
            span(choices[active + 1])
        } else {
            endSpan()
        }
    }

    /// Snaps to the choice at `index`, or back to the free selection when that
    /// choice is already active.
    func selectSpan(at index: Int) {
        let choices = spanChoices
        guard choices.indices.contains(index) else { return }
        if activeSpanIndex == index {
            endSpan()
        } else {
            span(choices[index])
        }
    }

    func spanAllScreens() {
        guard let choice = spanChoices.last else { return }
        span(choice)
    }

    private func span(_ choice: SpanChoice) {
        setSpannedDisplayIDs(choice.displayIDs)
        resnapSpan()
    }

    /// Returns to the selection in use before snapping.
    private func endSpan() {
        setSpannedDisplayIDs(nil)
        selectionRect = SelectionPreferences.load() ?? defaultSelectionRect()
    }

    /// Fits the selection to the spanned displays as they are arranged now, or
    /// ends the span when one of them is gone.
    private func resnapSpan() {
        guard let spannedDisplayIDs else { return }
        let frames = spannedDisplayIDs.compactMap { displayID in
            NSScreen.screens.first { $0.displayID == displayID }?.frame
        }
        guard frames.count == spannedDisplayIDs.count, frames.count >= 2 else {
            endSpan()
            return
        }
        selectionRect = SpanPlacement.bounds(of: frames).integral
    }

    private func setSpannedDisplayIDs(_ displayIDs: [CGDirectDisplayID]?) {
        guard spannedDisplayIDs != displayIDs else { return }
        spannedDisplayIDs = displayIDs
        SpanPreferences.save(displayIDs)
        onSpanChange?()
    }

    private func orderedScreens() -> [NSScreen] {
        NSScreen.screens.sorted { first, second in
            if first.frame.minX != second.frame.minX {
                return first.frame.minX < second.frame.minX
            }
            return first.frame.minY < second.frame.minY
        }
    }

    /// Drops updates that would strand the selection where no screen shows enough
    /// of it to grab: gaps in the display arrangement, or past the far edge of a
    /// smaller monitor. Moves compute the rect from the drag's absolute delta, so
    /// the selection catches up as soon as the cursor carries it back over a screen.
    private func applySelection(_ rect: CGRect) {
        guard SelectionPlacement.isReachable(rect, onScreens: NSScreen.screens.map(\.frame)) else {
            return
        }
        // Dragging or resizing a snapped selection makes it a free one again.
        if rect != selectionRect {
            setSpannedDisplayIDs(nil)
        }
        selectionRect = rect
    }

    private func screensDidChange() {
        let wasVisible = windows.contains { $0.isVisible }
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()

        if spannedDisplayIDs != nil {
            resnapSpan()
        } else if let selectionRect,
                  !SelectionPlacement.isReachable(selectionRect, onScreens: NSScreen.screens.map(\.frame)) {
            self.selectionRect = defaultSelectionRect()
        }

        if wasVisible {
            show()
        }
        // The monitors on offer may have changed even if the span did not.
        onSpanChange?()
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
        if options.span {
            selector.spanAllScreens()
        }
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

            if Self.isSpanScreensShortcut(event) {
                self?.selector.cycleSpan()
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
                },
                spanScreens: { [weak self] in
                    Task { @MainActor in
                        self?.selector.cycleSpan()
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
            },
            cycleSpan: { [weak self] in
                self?.selector.cycleSpan()
            },
            selectSpan: { [weak self] index in
                self?.selector.selectSpan(at: index)
            }
        )

        selector.onSpanChange = { [weak self] in
            self?.syncSpanToolbar()
        }
        syncSpanToolbar()
    }

    private func syncSpanToolbar() {
        toolbar.setSpan(choices: selector.spanChoices.map(\.title), activeIndex: selector.activeSpanIndex)
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

    private static func isSpanScreensShortcut(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return flags == [.command, .shift] && event.keyCode == UInt16(kVK_ANSI_B)
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
                        recordAudio: self.options.audio || toolbarSelection.recordAudio,
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
    struct Display {
        let id: CGDirectDisplayID
        let frame: CGRect
        let scale: CGFloat
        let bounds: CGRect
    }

    let selectionRect: CGRect
    /// Every display the selection touches, largest share first.
    let displays: [Display]
    private let mainDisplayHeight: CGFloat

    init(selectionRect: CGRect) throws {
        let displays = NSScreen.screens.compactMap { screen -> Display? in
            guard let displayID = screen.displayID,
                  screen.frame.intersection(selectionRect).area > 0
            else {
                return nil
            }
            return Display(
                id: displayID,
                frame: screen.frame,
                scale: screen.backingScaleFactor,
                bounds: CGDisplayBounds(displayID)
            )
        }.sorted { first, second in
            first.frame.intersection(selectionRect).area > second.frame.intersection(selectionRect).area
        }

        guard CaptureLayout(
            selection: selectionRect,
            screens: displays.map { (frame: $0.frame, scale: $0.scale) }
        ) != nil else {
            throw ScreenSnipperError.displayNotFound(selectionRect)
        }

        self.selectionRect = selectionRect
        self.displays = displays
        mainDisplayHeight = CGDisplayBounds(CGMainDisplayID()).height
    }

    private var layoutScreens: [(frame: CGRect, scale: CGFloat)] {
        displays.map { (frame: $0.frame, scale: $0.scale) }
    }

    /// The display holding most of the selection.
    var displayID: CGDirectDisplayID {
        displays[0].id
    }

    /// One frame of the selection. A selection on a single display comes back
    /// at that display's native size; one across displays is drawn into a single
    /// image that keeps their arrangement, already reduced to `maxWidth`.
    func captureImage(maxWidth: Int?) -> CGImage? {
        guard let layout = CaptureLayout(
            selection: selectionRect,
            screens: layoutScreens,
            maxWidth: maxWidth
        ) else {
            return nil
        }

        if layout.pieces.count == 1, let piece = layout.pieces.first {
            let display = displays[piece.screenIndex]
            return CGDisplayCreateImage(display.id, rect: displayRect(for: piece.sourceRect, on: display))
        }

        guard let context = CGContext(
            data: nil,
            width: layout.pixelWidth,
            height: layout.pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        // Space between offset displays belongs to none of them and stays black.
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: layout.pixelWidth, height: layout.pixelHeight))
        context.interpolationQuality = .medium

        var captured = false
        for piece in layout.pieces {
            let display = displays[piece.screenIndex]
            guard let image = CGDisplayCreateImage(display.id, rect: displayRect(for: piece.sourceRect, on: display)) else {
                continue
            }
            context.draw(image, in: piece.canvasRect)
            captured = true
        }
        return captured ? context.makeImage() : nil
    }

    /// Converts a rect in global screen points, which run up from the main
    /// display's bottom edge, to the top-left based rect CoreGraphics captures.
    private func displayRect(for sourceRect: CGRect, on display: Display) -> CGRect {
        CGRect(
            x: sourceRect.minX - display.bounds.minX,
            y: mainDisplayHeight - sourceRect.maxY - display.bounds.minY,
            width: sourceRect.width,
            height: sourceRect.height
        ).integral
    }

    var debugDescription: String {
        let layout = CaptureLayout(selection: selectionRect, screens: layoutScreens)
        let pieces = (layout?.pieces ?? []).map { piece in
            let display = displays[piece.screenIndex]
            return """
            displayID: \(display.id)
            screenFrame: \(display.frame)
            displayBounds: \(display.bounds)
            displayRect: \(displayRect(for: piece.sourceRect, on: display))
            canvasRect: \(piece.canvasRect)
            """
        }
        return (["selectionRect: \(selectionRect)"] + pieces).joined(separator: "\n")
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

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

            guard let capturedImage = region.captureImage(maxWidth: maxWidth) else {
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
        recordAudio: Bool,
        outputURL: URL,
        stopSignal: RecordingStopSignal
    ) async throws {
        try? FileManager.default.removeItem(at: outputURL)

        // Started before the first frame so no audio is missing from the start of
        // the recording; buffers are held until the writer session begins.
        let audioCapture = recordAudio ? try await SystemAudioCapture.start(displayID: region.displayID) : nil

        do {
            try await write(
                region: region,
                frameDuration: frameDuration,
                maxWidth: maxWidth,
                audioCapture: audioCapture,
                outputURL: outputURL,
                stopSignal: stopSignal
            )
        } catch {
            await audioCapture?.stop()
            throw error
        }
    }

    private static func write(
        region: CaptureRegion,
        frameDuration: TimeInterval,
        maxWidth: Int?,
        audioCapture: SystemAudioCapture?,
        outputURL: URL,
        stopSignal: RecordingStopSignal
    ) async throws {
        // Frames are stamped with the host clock, the same clock system audio
        // buffers carry, so the tracks stay in sync even when a capture runs slow.
        let startTime = hostTime()
        guard let firstCapture = region.captureImage(maxWidth: maxWidth) else {
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

        var audioInput: AVAssetWriterInput?
        if audioCapture != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: SystemAudioCapture.outputSettings)
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else {
                throw ScreenSnipperError.videoDestinationFailed(outputURL)
            }
            writer.add(input)
            audioInput = input
        }

        guard writer.startWriting() else {
            throw ScreenSnipperError.videoDestinationFailed(outputURL)
        }
        writer.startSession(atSourceTime: startTime)

        try append(firstImage, outputSize: outputSize, frameTime: startTime, adaptor: adaptor, input: input, outputURL: outputURL)
        if let audioCapture, let audioInput {
            audioCapture.beginWriting(to: audioInput, from: startTime)
        }

        while true {
            if await stopSignal.isStopped() {
                break
            }

            let targetTime = Date().addingTimeInterval(frameDuration)

            let frameTime = hostTime()
            guard let capturedImage = region.captureImage(maxWidth: maxWidth) else {
                continue
            }

            let image = resize(capturedImage, maxWidth: maxWidth) ?? capturedImage
            try append(image, outputSize: outputSize, frameTime: frameTime, adaptor: adaptor, input: input, outputURL: outputURL)

            let remaining = targetTime.timeIntervalSinceNow
            if remaining > 0 {
                try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            }
        }

        // Ending the session at the stop time keeps the last frame on screen until
        // then and trims any audio that arrived after it.
        let endTime = hostTime()
        await audioCapture?.stop()
        input.markAsFinished()
        writer.endSession(atSourceTime: endTime)
        await writer.finishWriting()

        if writer.status != .completed {
            throw ScreenSnipperError.videoFinalizeFailed(outputURL)
        }
    }

    private static func hostTime() -> CMTime {
        CMClockGetTime(CMClockGetHostTimeClock())
    }

    private static func append(
        _ image: CGImage,
        outputSize: (width: Int, height: Int),
        frameTime: CMTime,
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

/// Captures what the Mac is playing through ScreenCaptureKit. The tap sits ahead of
/// the output device, so speakers, headphones, and AirPlay all record the same way.
final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private static let sampleRate = 48_000
    private static let channelCount = 2

    static var outputSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channelCount,
            AVEncoderBitRateKey: 160_000
        ]
    }

    // All mutable state is confined to this queue, which also receives the samples.
    private let queue = DispatchQueue(label: "screen-snipper.system-audio")
    private var stream: SCStream?
    private var input: AVAssetWriterInput?
    private var startTime = CMTime.invalid
    private var pending: [CMSampleBuffer] = []

    static func start(displayID: CGDirectDisplayID) async throws -> SystemAudioCapture {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else {
                throw ScreenSnipperError.audioCaptureFailed("no display is available to capture.")
            }

            let configuration = SCStreamConfiguration()
            configuration.capturesAudio = true
            configuration.excludesCurrentProcessAudio = true
            configuration.sampleRate = sampleRate
            configuration.channelCount = channelCount
            // The stream always produces video too; frames come from CGDisplayCreateImage,
            // so keep the unused stream video as cheap as possible.
            configuration.width = 2
            configuration.height = 2
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)

            let capture = SystemAudioCapture()
            let stream = SCStream(
                filter: SCContentFilter(display: display, excludingWindows: []),
                configuration: configuration,
                delegate: capture
            )
            try stream.addStreamOutput(capture, type: .audio, sampleHandlerQueue: capture.queue)
            // Without a screen output the stream logs every video frame it has to drop.
            try stream.addStreamOutput(capture, type: .screen, sampleHandlerQueue: capture.queue)
            try await stream.startCapture()
            capture.queue.sync { capture.stream = stream }
            return capture
        } catch let error as ScreenSnipperError {
            throw error
        } catch {
            throw ScreenSnipperError.audioCaptureFailed(error.localizedDescription)
        }
    }

    /// Hands over the writer input once the session has started, flushing audio
    /// that arrived while the writer was being set up.
    func beginWriting(to input: AVAssetWriterInput, from startTime: CMTime) {
        queue.sync {
            self.input = input
            self.startTime = startTime
            let held = pending
            pending = []
            held.forEach(append)
        }
    }

    func stop() async {
        let stream = queue.sync { self.stream }
        try? await stream?.stopCapture()
        queue.sync {
            self.stream = nil
            input?.markAsFinished()
            input = nil
            pending = []
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else {
            return
        }

        if input == nil {
            // About two seconds of audio; setup takes far less than that.
            if pending.count < 200 {
                pending.append(sampleBuffer)
            }
            return
        }
        append(sampleBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        fputs("screen-snipper: system audio stopped: \(error.localizedDescription)\n", stderr)
    }

    private func append(_ sampleBuffer: CMSampleBuffer) {
        guard let input,
              sampleBuffer.presentationTimeStamp >= startTime,
              input.isReadyForMoreMediaData
        else {
            return
        }
        input.append(sampleBuffer)
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
