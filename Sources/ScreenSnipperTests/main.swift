import Foundation
import ScreenSnipperCore

struct TestFailure: Error, CustomStringConvertible {
    let message: String

    var description: String { message }
}

enum TestError: Error, Equatable {
    case registrationFailed(AppShortcut)
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() {
        throw TestFailure(message: message)
    }
}

func expectThrows<T: Error & Equatable>(
    _ expectedError: T,
    _ operation: () throws -> Void
) throws {
    do {
        try operation()
    } catch let error as T {
        try expect(error == expectedError, "Expected \(expectedError), got \(error)")
        return
    } catch {
        throw TestFailure(message: "Expected \(expectedError), got \(error)")
    }

    throw TestFailure(message: "Expected \(expectedError), but no error was thrown")
}

let tests: [(String, () throws -> Void)] = [
    ("parse defaults", {
        let options = try parseArguments(["screen-snipper"])

        try expect(options.fps == 10, "Default fps should be 10")
        try expect(options.maxWidth == nil, "Default maxWidth should be nil")
        try expect(options.output == nil, "Default output should be nil")
        try expect(options.copyToClipboard == false, "Default clipboard should be false")
        try expect(options.saveFile == true, "Default saveFile should be true")
        try expect(options.debug == false, "Default debug should be false")
        try expect(options.toggle == false, "Default toggle should be false")
    }),
    ("parse recording options", {
        let options = try parseArguments([
            "screen-snipper",
            "--fps", "5",
            "--max-width", "480",
            "--clipboard",
            "--debug"
        ])

        try expect(options.fps == 5, "FPS should parse")
        try expect(options.maxWidth == 480, "Max width should parse")
        try expect(options.copyToClipboard == true, "Clipboard should parse")
        try expect(options.debug == true, "Debug should parse")
    }),
    ("no-save implies clipboard", {
        let options = try parseArguments(["screen-snipper", "--no-save"])

        try expect(options.saveFile == false, "no-save should disable file preservation")
        try expect(options.copyToClipboard == true, "no-save should imply clipboard")
    }),
    ("parse toggle", {
        let options = try parseArguments(["screen-snipper", "--toggle"])

        try expect(options.toggle == true, "Toggle should parse")
    }),
    ("output expands tilde", {
        let options = try parseArguments(["screen-snipper", "--output", "~/Desktop/test.gif"])

        try expect(options.output?.path.hasSuffix("/Desktop/test.gif") == true, "Output suffix should match")
        try expect(options.output?.path.contains("~") == false, "Output should expand tilde")
    }),
    ("reject invalid fps", {
        try expectThrows(ScreenSnipperError.invalidOption("--fps requires a positive number.")) {
            _ = try parseArguments(["screen-snipper", "--fps", "0"])
        }
    }),
    ("default output uses Screenshot folder", {
        let date = Date(timeIntervalSince1970: 1_777_777_777)
        let home = URL(fileURLWithPath: "/Users/tester")
        let url = defaultOutputURL(date: date, homeDirectory: home)

        try expect(
            url.path.contains("/Users/tester/Desktop/Screenshot/screen-snipper-"),
            "Default output should be inside Desktop/Screenshot"
        )
        try expect(url.path.hasSuffix(".gif"), "Default output should be a GIF")
    }),
    ("default output supports custom base directory", {
        let date = Date(timeIntervalSince1970: 1_777_777_777)
        let url = defaultOutputURL(
            date: date,
            baseDirectory: URL(fileURLWithPath: "/Users/tester/Documents"),
            folderName: "Screen Snipper"
        )

        try expect(
            url.path.contains("/Users/tester/Documents/Screen Snipper/screen-snipper-"),
            "Custom output should use the provided base directory and folder"
        )
        try expect(url.path.hasSuffix(".gif"), "Custom output should be a GIF")
    }),
    ("default output can write directly into base directory", {
        let date = Date(timeIntervalSince1970: 1_777_777_777)
        let url = defaultOutputURL(
            date: date,
            baseDirectory: URL(fileURLWithPath: "/Users/tester/Desktop/Screenshot"),
            folderName: nil
        )

        try expect(
            url.path.contains("/Users/tester/Desktop/Screenshot/screen-snipper-"),
            "Direct output should not add a nested folder"
        )
        try expect(url.path.hasSuffix(".gif"), "Direct output should be a GIF")
    }),
    ("default output supports custom extension", {
        let date = Date(timeIntervalSince1970: 1_777_777_777)
        let url = defaultOutputURL(
            date: date,
            baseDirectory: URL(fileURLWithPath: "/Users/tester/Desktop/Screenshot"),
            folderName: nil,
            fileExtension: "mp4"
        )

        try expect(url.path.hasSuffix(".mp4"), "Custom extension should be used")
    }),
    ("clipboard temp url lives under /tmp/screen-snipper", {
        let date = Date(timeIntervalSince1970: 1_777_777_777)
        let url = clipboardTempURL(date: date, fileExtension: "mp4")

        try expect(
            url.path.hasPrefix("/tmp/screen-snipper/screen-snipper-"),
            "Clipboard temp file should live in /tmp/screen-snipper"
        )
        try expect(url.path.hasSuffix(".mp4"), "Clipboard temp file should use the recording extension")
    }),
    ("selection is reachable when fully on a screen", {
        let screens = [CGRect(x: 0, y: 0, width: 1920, height: 1080)]
        let rect = CGRect(x: 100, y: 100, width: 400, height: 300)

        try expect(
            SelectionPlacement.isReachable(rect, onScreens: screens),
            "A selection inside a screen should be reachable"
        )
    }),
    ("selection is reachable while spanning two screens", {
        let screens = [
            CGRect(x: 0, y: 0, width: 1920, height: 1080),
            CGRect(x: 1920, y: 0, width: 2560, height: 1440)
        ]
        let rect = CGRect(x: 1800, y: 100, width: 400, height: 300)

        try expect(
            SelectionPlacement.isReachable(rect, onScreens: screens),
            "A selection straddling adjacent screens should be reachable"
        )
    }),
    ("selection is unreachable in a gap between offset screens", {
        // A tall screen beside a shorter one leaves a region above the short
        // screen that belongs to no display.
        let screens = [
            CGRect(x: 0, y: 0, width: 1920, height: 2160),
            CGRect(x: 1920, y: 0, width: 1920, height: 1080)
        ]
        let rect = CGRect(x: 2000, y: 1200, width: 400, height: 300)

        try expect(
            !SelectionPlacement.isReachable(rect, onScreens: screens),
            "A selection in the dead zone should be unreachable"
        )
    }),
    ("selection is unreachable when only a sliver is visible", {
        let screens = [CGRect(x: 0, y: 0, width: 1920, height: 1080)]
        let rect = CGRect(x: 1910, y: 100, width: 400, height: 300)

        try expect(
            !SelectionPlacement.isReachable(rect, onScreens: screens),
            "A selection showing less than the minimum grabbable size should be unreachable"
        )
    }),
    ("selection sliver across two screens does not add up", {
        // 20 points visible on each side of a screen boundary is still less
        // than the minimum on either screen alone.
        let screens = [
            CGRect(x: 0, y: 0, width: 1920, height: 1080),
            CGRect(x: 1920, y: 1080, width: 1920, height: 1080)
        ]
        let rect = CGRect(x: 1900, y: 1060, width: 40, height: 40)

        try expect(
            !SelectionPlacement.isReachable(rect, onScreens: screens),
            "Corner slivers on separate screens should not count as reachable"
        )
    }),
    ("selection is unreachable with no screens", {
        let rect = CGRect(x: 0, y: 0, width: 400, height: 300)

        try expect(
            !SelectionPlacement.isReachable(rect, onScreens: []),
            "No screens means nothing is reachable"
        )
    }),
    ("moved selection keeps size and relative position on an equal screen", {
        let source = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let target = CGRect(x: 1920, y: 0, width: 1920, height: 1080)
        let rect = CGRect(x: 100, y: 200, width: 400, height: 300)

        let moved = SelectionPlacement.moved(rect, from: source, to: target)

        try expect(moved == CGRect(x: 2020, y: 200, width: 400, height: 300), "Moved rect should keep its relative spot, got \(moved)")
    }),
    ("moved selection shrinks to fit a smaller screen", {
        let source = CGRect(x: 0, y: 0, width: 3840, height: 2160)
        let target = CGRect(x: 3840, y: 0, width: 1440, height: 900)
        let rect = CGRect(x: 100, y: 100, width: 2000, height: 1200)

        let moved = SelectionPlacement.moved(rect, from: source, to: target)

        try expect(moved.width == 1440 && moved.height == 900, "Oversized rect should shrink to the target, got \(moved)")
        try expect(target.contains(moved), "Shrunk rect should lie inside the target, got \(moved)")
    }),
    ("moved selection clamps inside the target near an edge", {
        let source = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let target = CGRect(x: 1920, y: 0, width: 1440, height: 900)
        let rect = CGRect(x: 1520, y: 780, width: 400, height: 300)

        let moved = SelectionPlacement.moved(rect, from: source, to: target)

        try expect(target.contains(moved), "Edge-hugging rect should be clamped inside the target, got \(moved)")
        try expect(moved.width == 400 && moved.height == 300, "Clamping should not change a size that fits, got \(moved)")
    }),
    ("shortcut dispatcher routes shortcuts independently", {
        var recordCount = 0
        var closeCount = 0
        var moveScreenCount = 0
        let dispatcher = AppShortcutDispatcher(
            record: { recordCount += 1 },
            close: { closeCount += 1 },
            moveScreen: { moveScreenCount += 1 }
        )

        try expect(dispatcher.dispatch(id: AppShortcut.record.rawValue), "Record shortcut should dispatch")
        try expect(recordCount == 1, "Record action should run once")
        try expect(closeCount == 0, "Close action should not run for record shortcut")

        try expect(dispatcher.dispatch(id: AppShortcut.close.rawValue), "Close shortcut should dispatch")
        try expect(recordCount == 1, "Record action should not run for close shortcut")
        try expect(closeCount == 1, "Close action should run once")

        try expect(dispatcher.dispatch(id: AppShortcut.moveScreen.rawValue), "Move-screen shortcut should dispatch")
        try expect(moveScreenCount == 1, "Move-screen action should run once")
        try expect(recordCount == 1 && closeCount == 1, "Other actions should not run for move-screen shortcut")
    }),
    ("shortcut dispatcher ignores unknown shortcuts", {
        var actionCount = 0
        let dispatcher = AppShortcutDispatcher(
            record: { actionCount += 1 },
            close: { actionCount += 1 },
            moveScreen: { actionCount += 1 }
        )

        try expect(dispatcher.dispatch(id: 999) == false, "Unknown shortcut should not dispatch")
        try expect(actionCount == 0, "Unknown shortcut should not run any action")
    }),
    ("shortcut registration ignores optional failures", {
        var registered: [AppShortcut] = []
        var optionalFailures: [AppShortcut] = []

        try AppShortcutRegistrationPlan().registerAll(
            register: { shortcut in
                registered.append(shortcut)
                if shortcut != .record {
                    throw TestError.registrationFailed(shortcut)
                }
            },
            reportOptionalFailure: { shortcut, _ in
                optionalFailures.append(shortcut)
            }
        )

        try expect(registered == [.record, .close, .moveScreen], "All shortcuts should be attempted")
        try expect(optionalFailures == [.close, .moveScreen], "Optional failures should be reported")
    }),
    ("shortcut registration requires record", {
        var registered: [AppShortcut] = []

        do {
            try AppShortcutRegistrationPlan().registerAll { shortcut in
                registered.append(shortcut)
                if shortcut == .record {
                    throw TestError.registrationFailed(shortcut)
                }
            }
            try expect(false, "Record registration failure should throw")
        } catch TestError.registrationFailed(let shortcut) {
            try expect(shortcut == .record, "Record failure should propagate")
        }

        try expect(registered == [.record], "Optional shortcuts should not be attempted after record fails")
    })
]

var failures = 0

for (name, test) in tests {
    do {
        try test()
        print("PASS \(name)")
    } catch {
        failures += 1
        print("FAIL \(name): \(error)")
    }
}

if failures > 0 {
    Foundation.exit(1)
}

print("All \(tests.count) tests passed")
