import Foundation
import ScreenSnipperCore

struct TestFailure: Error, CustomStringConvertible {
    let message: String

    var description: String { message }
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
