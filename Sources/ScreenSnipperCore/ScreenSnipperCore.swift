import CoreGraphics
import Foundation

public struct Options: Equatable {
    public var fps: Double = 10
    public var maxWidth: Int?
    public var output: URL?
    public var copyToClipboard = false
    public var saveFile = true
    public var audio = false
    public var span = false
    public var debug = false
    public var toggle = false

    public init() {}
}

public enum AppShortcut: UInt32, Sendable {
    case record = 1
    case close = 2
    case moveScreen = 3
    case spanScreens = 4
}

public struct AppShortcutRegistrationPlan {
    public typealias Register = (AppShortcut) throws -> Void
    public typealias ReportOptionalFailure = (AppShortcut, Error) -> Void

    public init() {}

    public func registerAll(
        register: Register,
        reportOptionalFailure: ReportOptionalFailure? = nil
    ) throws {
        try register(.record)

        for shortcut in [AppShortcut.close, .moveScreen, .spanScreens] {
            do {
                try register(shortcut)
            } catch {
                reportOptionalFailure?(shortcut, error)
            }
        }
    }
}

public struct AppShortcutDispatcher {
    private let record: () -> Void
    private let close: () -> Void
    private let moveScreen: () -> Void
    private let spanScreens: () -> Void

    public init(
        record: @escaping () -> Void,
        close: @escaping () -> Void,
        moveScreen: @escaping () -> Void,
        spanScreens: @escaping () -> Void
    ) {
        self.record = record
        self.close = close
        self.moveScreen = moveScreen
        self.spanScreens = spanScreens
    }

    @discardableResult
    public func dispatch(id: UInt32) -> Bool {
        guard let shortcut = AppShortcut(rawValue: id) else {
            return false
        }

        switch shortcut {
        case .record:
            record()
        case .close:
            close()
        case .moveScreen:
            moveScreen()
        case .spanScreens:
            spanScreens()
        }
        return true
    }
}

public enum SelectionPlacement {
    /// Matches the minimum selection size; anything smaller is too little to see or grab.
    public static let minimumVisibleSize: CGFloat = 24

    /// Whether some screen shows a large enough piece of the rect for the user
    /// to see it and grab its border. Multi-monitor arrangements leave gaps in
    /// the global coordinate space where a rect exists but no display shows it.
    public static func isReachable(_ rect: CGRect, onScreens screens: [CGRect]) -> Bool {
        screens.contains { screen in
            let visible = screen.intersection(rect)
            return visible.width >= minimumVisibleSize && visible.height >= minimumVisibleSize
        }
    }

    /// Repositions a selection onto a target screen, keeping its size where it
    /// fits and its center at the same relative position it had on the source
    /// screen. The result always lies fully inside the target.
    public static func moved(_ rect: CGRect, from source: CGRect, to target: CGRect) -> CGRect {
        let width = min(rect.width, target.width)
        let height = min(rect.height, target.height)

        let relativeX = source.width > 0 ? (rect.midX - source.minX) / source.width : 0.5
        let relativeY = source.height > 0 ? (rect.midY - source.minY) / source.height : 0.5

        var origin = CGPoint(
            x: target.minX + relativeX * target.width - width / 2,
            y: target.minY + relativeY * target.height - height / 2
        )
        origin.x = min(max(origin.x, target.minX), target.maxX - width)
        origin.y = min(max(origin.y, target.minY), target.maxY - height)

        // Rounding down keeps the rect inside the target after clamping.
        return CGRect(
            x: origin.x.rounded(.down),
            y: origin.y.rounded(.down),
            width: width.rounded(.down),
            height: height.rounded(.down)
        )
    }
}

public enum SpanPlacement {
    /// The groups of screens a selection can snap to, as indices into `screens`.
    /// Two screens offer the pair; more offer every pair that shares an edge,
    /// then all of them. A pair that does not touch would take in whatever sits
    /// between it, so it is left to the all-screens choice.
    public static func choices(screens: [CGRect]) -> [[Int]] {
        guard screens.count >= 2 else { return [] }
        guard screens.count > 2 else { return [[0, 1]] }

        var choices: [[Int]] = []
        for first in screens.indices {
            for second in screens.indices where second > first && sharesEdge(screens[first], screens[second]) {
                choices.append([first, second])
            }
        }
        choices.append(Array(screens.indices))
        return choices
    }

    /// The smallest rect covering every given screen.
    public static func bounds(of screens: [CGRect]) -> CGRect {
        screens.reduce(CGRect.null) { $0.union($1) }
    }

    private static func sharesEdge(_ first: CGRect, _ second: CGRect) -> Bool {
        // Growing one rect by a point makes neighbours overlap along their shared
        // edge; screens that only meet at a corner overlap in a single point.
        let overlap = first.insetBy(dx: -1, dy: -1).intersection(second)
        return !overlap.isNull && max(overlap.width, overlap.height) > 2
    }
}

/// Where each screen's part of a selection lands in the recorded frame. Screens
/// keep their arrangement, so space no screen covers is left empty.
public struct CaptureLayout: Equatable {
    public struct Piece: Equatable {
        public let screenIndex: Int
        /// The part of the selection on this screen, in global screen points.
        public let sourceRect: CGRect
        /// Where that part is drawn, in frame pixels from the bottom-left corner.
        public let canvasRect: CGRect
    }

    public let pieces: [Piece]
    public let pixelWidth: Int
    public let pixelHeight: Int

    /// Returns nil when the selection lies on no screen. The frame uses the
    /// sharpest screen's scale, so a lower-density screen is scaled up to match,
    /// and is reduced as a whole when it would be wider than `maxWidth`.
    public init?(selection: CGRect, screens: [(frame: CGRect, scale: CGFloat)], maxWidth: Int? = nil) {
        var parts: [(index: Int, rect: CGRect)] = []
        for (index, screen) in screens.enumerated() {
            let visible = screen.frame.intersection(selection)
            guard !visible.isNull else { continue }
            let rect = visible.integral
            if rect.width >= 1, rect.height >= 1 {
                parts.append((index, rect))
            }
        }
        guard !parts.isEmpty else { return nil }

        let bounds = SpanPlacement.bounds(of: parts.map { $0.rect })
        var scale = parts.map { screens[$0.index].scale }.max() ?? 1
        if let maxWidth, bounds.width * scale > CGFloat(maxWidth) {
            scale = CGFloat(maxWidth) / bounds.width
        }

        pixelWidth = max(1, Int((bounds.width * scale).rounded()))
        pixelHeight = max(1, Int((bounds.height * scale).rounded()))
        pieces = parts.map { part in
            Piece(
                screenIndex: part.index,
                sourceRect: part.rect,
                canvasRect: CGRect(
                    x: (part.rect.minX - bounds.minX) * scale,
                    y: (part.rect.minY - bounds.minY) * scale,
                    width: part.rect.width * scale,
                    height: part.rect.height * scale
                )
            )
        }
    }
}

public enum ScreenSnipperError: Error, CustomStringConvertible, Equatable {
    case invalidOption(String)
    case screenRecordingPermissionDenied
    case selectionCancelled
    case captureFailed
    case displayNotFound(CGRect)
    case gifDestinationFailed(URL)
    case gifFinalizeFailed(URL)
    case videoDestinationFailed(URL)
    case videoFrameAppendFailed(URL)
    case videoFinalizeFailed(URL)
    case audioCaptureFailed(String)
    case noFramesCaptured

    public var description: String {
        switch self {
        case .invalidOption(let message): message
        case .screenRecordingPermissionDenied:
            """
            Screen Recording permission is required.
            Enable it for the app that launched screen-snipper, usually Terminal, iTerm, or the screen-snipper executable, in System Settings > Privacy & Security > Screen & System Audio Recording. Then quit and reopen that app before trying again.
            """
        case .selectionCancelled: "Selection cancelled."
        case .captureFailed: "Could not capture the selected screen area."
        case .displayNotFound(let rect): "Could not find a display for selected rect \(rect)."
        case .gifDestinationFailed(let url): "Could not create GIF at \(url.path)."
        case .gifFinalizeFailed(let url): "Could not finish GIF at \(url.path)."
        case .videoDestinationFailed(let url): "Could not create video at \(url.path)."
        case .videoFrameAppendFailed(let url): "Could not add a frame to video at \(url.path)."
        case .videoFinalizeFailed(let url): "Could not finish video at \(url.path)."
        case .audioCaptureFailed(let message): "Could not capture system audio: \(message)"
        case .noFramesCaptured: "No frames were captured."
        }
    }

    public static func == (lhs: ScreenSnipperError, rhs: ScreenSnipperError) -> Bool {
        switch (lhs, rhs) {
        case (.invalidOption(let left), .invalidOption(let right)),
             (.audioCaptureFailed(let left), .audioCaptureFailed(let right)):
            left == right
        case (.screenRecordingPermissionDenied, .screenRecordingPermissionDenied),
             (.selectionCancelled, .selectionCancelled),
             (.captureFailed, .captureFailed),
             (.noFramesCaptured, .noFramesCaptured):
            true
        case (.displayNotFound(let left), .displayNotFound(let right)):
            left.origin.x == right.origin.x &&
                left.origin.y == right.origin.y &&
                left.size.width == right.size.width &&
                left.size.height == right.size.height
        case (.gifDestinationFailed(let left), .gifDestinationFailed(let right)),
             (.gifFinalizeFailed(let left), .gifFinalizeFailed(let right)),
             (.videoDestinationFailed(let left), .videoDestinationFailed(let right)),
             (.videoFrameAppendFailed(let left), .videoFrameAppendFailed(let right)),
             (.videoFinalizeFailed(let left), .videoFinalizeFailed(let right)):
            left == right
        default:
            false
        }
    }
}

public func parseArguments(_ arguments: [String]) throws -> Options {
    var options = Options()
    var index = 1

    while index < arguments.count {
        let argument = arguments[index]

        switch argument {
        case "--fps":
            index += 1
            guard index < arguments.count, let fps = Double(arguments[index]), fps > 0 else {
                throw ScreenSnipperError.invalidOption("--fps requires a positive number.")
            }
            options.fps = fps
        case "--max-width":
            index += 1
            guard index < arguments.count, let maxWidth = Int(arguments[index]), maxWidth > 0 else {
                throw ScreenSnipperError.invalidOption("--max-width requires a positive integer.")
            }
            options.maxWidth = maxWidth
        case "--output":
            index += 1
            guard index < arguments.count else {
                throw ScreenSnipperError.invalidOption("--output requires a path.")
            }
            options.output = URL(fileURLWithPath: NSString(string: arguments[index]).expandingTildeInPath)
        case "--clipboard":
            options.copyToClipboard = true
        case "--no-save":
            options.saveFile = false
            options.copyToClipboard = true
        case "--audio":
            options.audio = true
        case "--span":
            options.span = true
        case "--debug":
            options.debug = true
        case "--toggle":
            options.toggle = true
        case "--help", "-h":
            printUsage()
            Foundation.exit(0)
        default:
            throw ScreenSnipperError.invalidOption("Unknown option: \(argument)")
        }

        index += 1
    }

    return options
}

public func defaultOutputURL(
    date: Date,
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
    baseDirectory: URL? = nil,
    folderName: String? = "Screenshot",
    fileExtension: String = "gif"
) -> URL {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    let filename = "screen-snipper-\(formatter.string(from: date)).\(fileExtension)"
    let baseDirectory = baseDirectory ?? homeDirectory.appendingPathComponent("Desktop")
    let directory = folderName.map { baseDirectory.appendingPathComponent($0) } ?? baseDirectory
    return directory.appendingPathComponent(filename)
}

/// Location for a clipboard-only recording. macOS pastes video by file URL, so the
/// recording has to outlive the process instead of being deleted after the copy.
public func clipboardTempURL(
    date: Date,
    baseDirectory: URL = URL(fileURLWithPath: "/tmp", isDirectory: true),
    fileExtension: String = "gif"
) -> URL {
    defaultOutputURL(
        date: date,
        baseDirectory: baseDirectory,
        folderName: "screen-snipper",
        fileExtension: fileExtension
    )
}

public func printUsage() {
    print("""
    Usage: screen-snipper [options]

    Options:
      --fps <frames>        Frames per second. Defaults to 10.
      --max-width <pixels>  Downscale captures wider than this value.
      --output <path>       Output path. Defaults to ~/Desktop/Screenshot/screen-snipper-YYYYMMDD-HHMMSS.gif.
      --clipboard           Copy the recording to the clipboard after saving.
      --no-save             Copy to clipboard only; the file is kept in /tmp/screen-snipper.
      --audio               Record system audio with Video recordings.
      --span                Start with the capture area snapped to all monitors.
      --debug               Print capture coordinate diagnostics.
      --toggle              Start screen-snipper if closed, or close the running instance.
      --help                Show this help.
    """)
}
