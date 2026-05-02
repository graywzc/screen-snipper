import AppKit
import CoreGraphics
import Foundation
import GifSnipCore
import ImageIO
import UniformTypeIdentifiers

@MainActor
final class SelectionView: NSView {
    var onSelection: ((CGRect?) -> Void)?

    private var startPoint: NSPoint?
    private var currentRect: NSRect = .zero

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        window?.makeFirstResponder(self)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.28).setFill()
        bounds.fill()

        guard !currentRect.isEmpty else { return }

        NSColor.clear.setFill()
        currentRect.fill(using: .clear)

        NSColor.systemBlue.setStroke()
        let path = NSBezierPath(rect: currentRect)
        path.lineWidth = 2
        path.stroke()

        NSColor.systemBlue.withAlphaComponent(0.12).setFill()
        currentRect.fill()
    }

    override func mouseDown(with event: NSEvent) {
        startPoint = convert(event.locationInWindow, from: nil)
        currentRect = .zero
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let startPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        currentRect = NSRect(
            x: min(startPoint.x, point.x),
            y: min(startPoint.y, point.y),
            width: abs(startPoint.x - point.x),
            height: abs(startPoint.y - point.y)
        )
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let window else {
            onSelection?(nil)
            return
        }

        if currentRect.width < 4 || currentRect.height < 4 {
            onSelection?(nil)
            return
        }

        let windowRect = convert(currentRect, to: nil)
        let screenRect = window.convertToScreen(windowRect)
        onSelection?(screenRect)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onSelection?(nil)
        } else {
            super.keyDown(with: event)
        }
    }
}

@MainActor
final class SelectionController {
    private var windows: [NSWindow] = []
    private var completion: ((CGRect?) -> Void)?

    func begin(completion: @escaping (CGRect?) -> Void) {
        self.completion = completion

        for screen in NSScreen.screens {
            let view = SelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.onSelection = { [weak self] rect in
                self?.finish(rect)
            }

            let window = NSWindow(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.level = .screenSaver
            window.backgroundColor = .clear
            window.isOpaque = false
            window.ignoresMouseEvents = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.contentView = view
            window.makeKeyAndOrderFront(nil)
            windows.append(window)
        }

        NSCursor.crosshair.set()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func finish(_ rect: CGRect?) {
        NSCursor.arrow.set()
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        completion?(rect)
        completion = nil
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let options: Options
    private let selector = SelectionController()

    init(options: Options) {
        self.options = options
    }

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            try Permissions.ensureScreenRecording()
        } catch {
            fputs("gif-snip: \(error)\n", stderr)
            NSApp.terminate(nil)
            return
        }

        selector.begin { [weak self] rect in
            guard let self else { return }
            Task {
                do {
                    guard let rect else {
                        throw GifSnipError.selectionCancelled
                    }

                    let outputURL = try self.outputURL()
                    let frameCount = max(1, Int((self.options.duration * self.options.fps).rounded()))
                    let delay = 1 / self.options.fps
                    let region = try CaptureRegion(selectionRect: rect)
                    if self.options.debug {
                        fputs("\(region.debugDescription)\n", stderr)
                    }

                    try await Task.sleep(nanoseconds: 150_000_000)

                    try await GifRecorder.record(
                        region: region,
                        frameCount: frameCount,
                        delay: delay,
                        maxWidth: self.options.maxWidth,
                        outputURL: outputURL
                    )

                    if self.options.copyToClipboard {
                        try Clipboard.copyGIF(from: outputURL, includeFileURL: self.options.saveFile)
                    }

                    if !self.options.saveFile {
                        try? FileManager.default.removeItem(at: outputURL)
                    }

                    print(self.successMessage(outputURL: outputURL))
                    NSApp.terminate(nil)
                } catch {
                    fputs("gif-snip: \(error)\n", stderr)
                    NSApp.terminate(nil)
                }
            }
        }
    }

    private func outputURL() throws -> URL {
        if let output = options.output {
            return output
        }

        if !options.saveFile {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("gif-snip-\(UUID().uuidString)")
                .appendingPathExtension("gif")
        }

        let outputURL = defaultOutputURL(date: Date())
        let outputDirectory = outputURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        return outputURL
    }

    private func successMessage(outputURL: URL) -> String {
        switch (options.saveFile, options.copyToClipboard) {
        case (true, true):
            "Saved \(outputURL.path) and copied GIF to clipboard"
        case (true, false):
            "Saved \(outputURL.path)"
        case (false, true):
            "Copied GIF to clipboard"
        case (false, false):
            "Done"
        }
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
            throw GifSnipError.displayNotFound(selectionRect)
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

enum GifRecorder {
    static func record(
        region: CaptureRegion,
        frameCount: Int,
        delay: TimeInterval,
        maxWidth: Int?,
        outputURL: URL
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

        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL,
            UTType.gif.identifier as CFString,
            frameCount,
            nil
        ) else {
            throw GifSnipError.gifDestinationFailed(outputURL)
        }

        CGImageDestinationSetProperties(destination, fileProperties)

        var capturedFrames = 0
        for index in 0..<frameCount {
            let targetTime = Date().addingTimeInterval(delay)

            guard let capturedImage = CGDisplayCreateImage(region.displayID, rect: region.displayRect) else {
                if index == 0 {
                    throw GifSnipError.captureFailed
                }
                continue
            }

            let image = resize(capturedImage, maxWidth: maxWidth) ?? capturedImage
            CGImageDestinationAddImage(destination, image, frameProperties)
            capturedFrames += 1

            let remaining = targetTime.timeIntervalSinceNow
            if remaining > 0 {
                try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            }
        }

        guard capturedFrames > 0 else {
            throw GifSnipError.noFramesCaptured
        }

        if !CGImageDestinationFinalize(destination) {
            throw GifSnipError.gifFinalizeFailed(outputURL)
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

enum Permissions {
    static func ensureScreenRecording() throws {
        if CGPreflightScreenCaptureAccess() {
            return
        }

        if CGRequestScreenCaptureAccess() {
            return
        }

        throw GifSnipError.screenRecordingPermissionDenied
    }
}

enum Clipboard {
    static func copyGIF(from url: URL, includeFileURL: Bool) throws {
        let data = try Data(contentsOf: url)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        let item = NSPasteboardItem()
        item.setData(data, forType: NSPasteboard.PasteboardType(UTType.gif.identifier))

        if includeFileURL {
            item.setString(url.absoluteString, forType: .fileURL)
            item.setString(url.absoluteString, forType: .URL)
        }

        pasteboard.writeObjects([item])
    }
}

do {
    let options = try parseArguments(CommandLine.arguments)
    let app = NSApplication.shared
    let delegate = AppDelegate(options: options)
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
} catch {
    fputs("gif-snip: \(error)\n", stderr)
    Foundation.exit(1)
}
