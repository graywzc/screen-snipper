import Foundation

public struct Options: Equatable {
    public var duration: TimeInterval = 3
    public var fps: Double = 10
    public var maxWidth: Int?
    public var output: URL?
    public var copyToClipboard = false
    public var saveFile = true
    public var debug = false

    public init() {}
}

public enum GifSnipError: Error, CustomStringConvertible, Equatable {
    case invalidOption(String)
    case screenRecordingPermissionDenied
    case selectionCancelled
    case captureFailed
    case displayNotFound(CGRect)
    case gifDestinationFailed(URL)
    case gifFinalizeFailed(URL)
    case noFramesCaptured

    public var description: String {
        switch self {
        case .invalidOption(let message): message
        case .screenRecordingPermissionDenied:
            """
            Screen Recording permission is required.
            Enable it for the app that launched gif-snip, usually Terminal, iTerm, or the gif-snip executable, in System Settings > Privacy & Security > Screen & System Audio Recording. Then quit and reopen that app before trying again.
            """
        case .selectionCancelled: "Selection cancelled."
        case .captureFailed: "Could not capture the selected screen area."
        case .displayNotFound(let rect): "Could not find a display for selected rect \(rect)."
        case .gifDestinationFailed(let url): "Could not create GIF at \(url.path)."
        case .gifFinalizeFailed(let url): "Could not finish GIF at \(url.path)."
        case .noFramesCaptured: "No frames were captured."
        }
    }

    public static func == (lhs: GifSnipError, rhs: GifSnipError) -> Bool {
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
             (.gifFinalizeFailed(let left), .gifFinalizeFailed(let right)):
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
        case "--duration":
            index += 1
            guard index < arguments.count, let duration = Double(arguments[index]), duration > 0 else {
                throw GifSnipError.invalidOption("--duration requires a positive number.")
            }
            options.duration = duration
        case "--fps":
            index += 1
            guard index < arguments.count, let fps = Double(arguments[index]), fps > 0 else {
                throw GifSnipError.invalidOption("--fps requires a positive number.")
            }
            options.fps = fps
        case "--max-width":
            index += 1
            guard index < arguments.count, let maxWidth = Int(arguments[index]), maxWidth > 0 else {
                throw GifSnipError.invalidOption("--max-width requires a positive integer.")
            }
            options.maxWidth = maxWidth
        case "--output":
            index += 1
            guard index < arguments.count else {
                throw GifSnipError.invalidOption("--output requires a path.")
            }
            options.output = URL(fileURLWithPath: NSString(string: arguments[index]).expandingTildeInPath)
        case "--clipboard":
            options.copyToClipboard = true
        case "--no-save":
            options.saveFile = false
            options.copyToClipboard = true
        case "--debug":
            options.debug = true
        case "--help", "-h":
            printUsage()
            Foundation.exit(0)
        default:
            throw GifSnipError.invalidOption("Unknown option: \(argument)")
        }

        index += 1
    }

    return options
}

public func defaultOutputURL(date: Date, homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    let filename = "gif-snip-\(formatter.string(from: date)).gif"
    return homeDirectory
        .appendingPathComponent("Desktop")
        .appendingPathComponent("Screenshot")
        .appendingPathComponent(filename)
}

public func printUsage() {
    print("""
    Usage: gif-snip [options]

    Options:
      --duration <seconds>  Recording length. Defaults to 3.
      --fps <frames>        Frames per second. Defaults to 10.
      --max-width <pixels>   Downscale GIF frames to this width when larger.
      --output <path>       GIF output path. Defaults to ~/Desktop/Screenshot/gif-snip-YYYYMMDD-HHMMSS.gif.
      --clipboard           Copy the GIF to the clipboard after saving.
      --no-save             Copy to clipboard without keeping a file.
      --debug               Print capture coordinate diagnostics.
      --help                Show this help.
    """)
}
