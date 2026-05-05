import AppKit
import ScreenSnipperCore
import SwiftUI

enum RecordingFormat: String, CaseIterable, Identifiable {
    case gif = "GIF"
    case video = "Video"

    var id: String { rawValue }

    var fileExtension: String {
        switch self {
        case .gif:
            "gif"
        case .video:
            "mp4"
        }
    }
}

enum RecordingFPS: Double, CaseIterable, Identifiable {
    case ten = 10
    case fifteen = 15
    case twentyFour = 24

    var id: Double { rawValue }

    var title: String {
        "\(Int(rawValue)) FPS"
    }

    static func closest(to fps: Double) -> RecordingFPS {
        allCases.min { first, second in
            abs(first.rawValue - fps) < abs(second.rawValue - fps)
        } ?? .ten
    }
}

enum RecordingMaxWidth: Int, CaseIterable, Identifiable {
    case original = 0
    case small = 480
    case medium = 720
    case large = 1080

    var id: Int { rawValue }

    var value: Int? {
        rawValue == 0 ? nil : rawValue
    }

    var title: String {
        value.map { "\($0) px" } ?? "Original"
    }

    static func closest(to maxWidth: Int?) -> RecordingMaxWidth {
        guard let maxWidth else { return .original }
        return allCases.filter { $0.value != nil }.min { first, second in
            abs(first.rawValue - maxWidth) < abs(second.rawValue - maxWidth)
        } ?? .medium
    }
}

enum CaptureToolbarPreferences {
    private static let saveToFolderKey = "captureToolbar.saveToFolder"
    private static let copyToClipboardKey = "captureToolbar.copyToClipboard"
    private static let folderURLKey = "captureToolbar.folderURL"
    private static let formatKey = "captureToolbar.format"
    private static let fpsKey = "captureToolbar.fps"
    private static let maxWidthKey = "captureToolbar.maxWidth"

    static func save(_ selection: CaptureToolbarSelection) {
        let defaults = UserDefaults.standard
        defaults.set(selection.saveToFolder, forKey: saveToFolderKey)
        defaults.set(selection.copyToClipboard, forKey: copyToClipboardKey)
        defaults.set(selection.folderURL.path, forKey: folderURLKey)
        defaults.set(selection.format.rawValue, forKey: formatKey)
        defaults.set(selection.fps, forKey: fpsKey)
        defaults.set(selection.maxWidth ?? 0, forKey: maxWidthKey)
    }

    static func saveToFolder(fallback: Bool) -> Bool {
        guard UserDefaults.standard.object(forKey: saveToFolderKey) != nil else {
            return fallback
        }
        return UserDefaults.standard.bool(forKey: saveToFolderKey)
    }

    static func copyToClipboard(fallback: Bool) -> Bool {
        guard UserDefaults.standard.object(forKey: copyToClipboardKey) != nil else {
            return fallback
        }
        return UserDefaults.standard.bool(forKey: copyToClipboardKey)
    }

    static func folderURL() -> URL {
        if let path = UserDefaults.standard.string(forKey: folderURLKey), !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return defaultFolderURL()
    }

    static func format() -> RecordingFormat {
        guard let rawValue = UserDefaults.standard.string(forKey: formatKey) else {
            return .gif
        }
        return RecordingFormat(rawValue: rawValue) ?? .gif
    }

    static func defaultFolderURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop")
            .appendingPathComponent("Screenshot")
    }

    static func fps(fallback: Double) -> RecordingFPS {
        let value = UserDefaults.standard.double(forKey: fpsKey)
        return value > 0 ? .closest(to: value) : .closest(to: fallback)
    }

    static func maxWidth(fallback: Int?) -> RecordingMaxWidth {
        guard UserDefaults.standard.object(forKey: maxWidthKey) != nil else {
            return .closest(to: fallback)
        }
        let value = UserDefaults.standard.integer(forKey: maxWidthKey)
        return .closest(to: value == 0 ? nil : value)
    }
}

struct CaptureToolbarSelection {
    var format: RecordingFormat
    var saveToFolder: Bool
    var folderURL: URL
    var copyToClipboard: Bool
    var fps: Double
    var maxWidth: Int?
}

@MainActor
final class CaptureToolbarState: ObservableObject {
    @Published var isRecording = false
    @Published var format: RecordingFormat {
        didSet { persist() }
    }
    @Published var saveToFolder: Bool {
        didSet { persist() }
    }
    @Published var folderURL: URL {
        didSet { persist() }
    }
    @Published var copyToClipboard: Bool {
        didSet { persist() }
    }
    @Published var fps: RecordingFPS {
        didSet { persist() }
    }
    @Published var maxWidth: RecordingMaxWidth {
        didSet { persist() }
    }

    init(options: Options) {
        format = CaptureToolbarPreferences.format()
        saveToFolder = CaptureToolbarPreferences.saveToFolder(fallback: options.saveFile)
        copyToClipboard = CaptureToolbarPreferences.copyToClipboard(fallback: options.copyToClipboard || !options.saveFile)
        folderURL = options.output?.deletingLastPathComponent() ?? CaptureToolbarPreferences.folderURL()
        fps = CaptureToolbarPreferences.fps(fallback: options.fps)
        maxWidth = CaptureToolbarPreferences.maxWidth(fallback: options.maxWidth)
    }

    var selection: CaptureToolbarSelection {
        CaptureToolbarSelection(
            format: format,
            saveToFolder: saveToFolder,
            folderURL: folderURL,
            copyToClipboard: copyToClipboard,
            fps: fps.rawValue,
            maxWidth: maxWidth.value
        )
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = folderURL
        panel.prompt = "Choose"

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        folderURL = url
        saveToFolder = true
    }

    private func persist() {
        CaptureToolbarPreferences.save(selection)
    }
}

@MainActor
final class CaptureToolbarController {
    private var panel: NSPanel?
    private let state: CaptureToolbarState
    private var recordToggle: ((CaptureToolbarSelection) -> Void)?
    private var cancelAction: (() -> Void)?

    init(options: Options) {
        state = CaptureToolbarState(options: options)
    }

    func begin(
        recordToggle: @escaping (CaptureToolbarSelection) -> Void,
        cancel: @escaping () -> Void
    ) {
        self.recordToggle = recordToggle
        cancelAction = cancel

        if panel == nil {
            panel = makePanel()
        }

        guard let panel else { return }
        position(panel)
        panel.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    func toggleRecordingFromShortcut() {
        recordToggle?(state.selection)
    }

    func setRecording(_ isRecording: Bool) {
        state.isRecording = isRecording
    }

    func hide() {
        panel?.orderOut(nil)
    }

    func show() {
        panel?.orderFrontRegardless()
    }

    func cancel() {
        panel?.orderOut(nil)
        cancelAction?()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 458, height: 74),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.isMovable = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.sharingType = .none
        panel.contentView = ToolbarHostingView(
            rootView: CaptureToolbarView(
                state: state,
                cancel: { [weak self] in self?.cancel() },
                toggleRecording: { [weak self] in
                    guard let self else { return }
                    self.recordToggle?(self.state.selection)
                }
            )
        )
        return panel
    }

    private func position(_ panel: NSPanel) {
        let screenFrame = NSScreen.main?.visibleFrame ?? .zero
        let size = panel.frame.size
        let origin = NSPoint(
            x: screenFrame.midX - size.width / 2,
            y: screenFrame.minY + 28
        )
        panel.setFrameOrigin(origin)
    }
}

struct CaptureToolbarView: View {
    @ObservedObject var state: CaptureToolbarState
    let cancel: () -> Void
    let toggleRecording: () -> Void

    @State private var showsRecordShortcut = false

    var body: some View {
        HStack(spacing: 12) {
            Picker("Format", selection: $state.format) {
                ForEach(RecordingFormat.allCases) { format in
                    Text(format.rawValue).tag(format)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 116)

            optionsMenu

            Button(action: toggleRecording) {
                Text(recordButtonTitle)
                    .foregroundStyle(.black)
                    .frame(width: 150)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.12)) {
                    showsRecordShortcut = hovering
                }
            }

            Button {
                cancel()
            } label: {
                Image(systemName: "xmark")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help("Cancel")
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.ultraThickMaterial, in: Capsule())
        .overlay {
            Capsule()
                .stroke(.white.opacity(0.18), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.24), radius: 18, y: 8)
        .frame(width: 458, height: 74)
        .help("Drag to move")
    }

    private var recordButtonTitle: String {
        showsRecordShortcut ? "⌘ ⇧ Space" : (state.isRecording ? "Stop" : "Record")
    }

    private var optionsMenu: some View {
        Menu {
            Toggle("Save to Local Folder", isOn: $state.saveToFolder)

            Button {
                state.chooseFolder()
            } label: {
                Text("Choose Folder...")
            }

            Text(state.folderURL.path)

            Toggle("Copy to Clipboard", isOn: $state.copyToClipboard)

            Divider()

            Picker("Frame Rate", selection: $state.fps) {
                ForEach(RecordingFPS.allCases) { fps in
                    Text(fps.title).tag(fps)
                }
            }

            Picker("Max Width", selection: $state.maxWidth) {
                ForEach(RecordingMaxWidth.allCases) { maxWidth in
                    Text(maxWidth.title).tag(maxWidth)
                }
            }
        } label: {
            Label("Options", systemImage: "chevron.up.chevron.down")
                .labelStyle(.titleAndIcon)
        }
        .menuStyle(.button)
        .controlSize(.large)
        .fixedSize()
    }
}

private final class ToolbarHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool {
        true
    }
}
