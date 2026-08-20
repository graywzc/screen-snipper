import CoreGraphics
import Foundation

public struct Options: Equatable {
    public var fps: Double = 10
    public var maxWidth: Int?
    public var output: URL?
    public var copyToClipboard = false
    public var saveFile = true
    public var debug = false
    public var toggle = false

    public init() {}
}

public enum AppShortcut: UInt32, Sendable {
    case record = 1
    case close = 2
    case moveScreen = 3
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

        for shortcut in [AppShortcut.close, .moveScreen] {
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

    public init(
        record: @escaping () -> Void,
        close: @escaping () -> Void,
        moveScreen: @escaping () -> Void
    ) {
        self.record = record
        self.close = close
        self.moveScreen = moveScreen
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
        case .noFramesCaptured: "No frames were captured."
        }
    }

    public static func == (lhs: ScreenSnipperError, rhs: ScreenSnipperError) -> Bool {
        switch (lhs, rhs) {
        case (.invalidOption(let left), .invalidOption(let right)):
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
      --debug               Print capture coordinate diagnostics.
      --toggle              Start screen-snipper if closed, or close the running instance.
      --help                Show this help.
    """)
}
