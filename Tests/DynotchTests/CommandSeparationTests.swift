import Foundation
import Testing

/// The `dynotch` command runs what it's told to, as with a status line's `--then`, and macOS gives
/// permissions to a signed identity, so it has to stay out of the app. These read the source and the
/// build, so it stays that way.
struct CommandSeparationTests {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func text(of path: String) throws -> String {
        try String(contentsOf: Self.root.appendingPathComponent(path), encoding: .utf8)
    }

    private func sources(in folders: String...) throws -> [(name: String, text: String)] {
        var sources: [(name: String, text: String)] = []
        for folder in folders {
            let files = try #require(FileManager.default.enumerator(at: Self.root.appendingPathComponent(folder), includingPropertiesForKeys: nil))
            for case let file as URL in files where file.pathExtension == "swift" {
                sources.append((file.lastPathComponent, try String(contentsOf: file, encoding: .utf8)))
            }
        }
        return sources
    }

    /// Every source file that ends up in the app.
    private func appSources() throws -> [(name: String, text: String)] {
        let sources = try sources(in: "Sources/Dynotch", "Sources/DynotchShared")
        #expect(sources.count > 100)
        return sources
    }

    @Test func theAppDoesntLinkTheCommand() throws {
        let package = try text(of: "Package.swift")
        let app = try #require(package.range(of: "name: \"Dynotch\",\n            dependencies:"))
        let target = package[app.lowerBound...].prefix { $0 != ")" }
        #expect(target.contains("DynotchShared"))
        #expect(!target.contains("DynotchCommand"))
        #expect(try appSources().filter { $0.text.contains("import DynotchCommand") }.isEmpty)
    }

    @Test func theAppTakesNoCommands() throws {
        let named = try appSources().filter { $0.text.contains("\"--cli\"") || $0.text.contains("CommandLineClient") }
        #expect(named.map(\.name) == [])
    }

    /// A child of the app would have all that the app has been allowed, so the app never starts it.
    @Test func theAppNeverStartsTheCommand() throws {
        let named = try appSources().filter { $0.text.contains("\"DynotchCommand\"") || $0.text.contains("Helpers/") }
        #expect(named.map(\.name) == [])
    }

    @Test func theCommandKeepsToFoundation() throws {
        let sources = try sources(in: "Sources/DynotchCommand", "Sources/DynotchShared")
        #expect(sources.count > 5)
        let allowed: Set = ["import Darwin", "import DynotchShared", "import Foundation"]
        for source in sources {
            let imports = source.text.split(separator: "\n").filter { $0.hasPrefix("import ") }.map(String.init)
            #expect(Set(imports).isSubset(of: allowed), "\(source.name) imports \(imports)")
        }
    }

    /// Whoever starts the app chooses its environment, so nothing in it can name what the app acts on.
    @Test func theAppReadsNothingFromItsEnvironment() throws {
        let named = try appSources().filter { $0.text.contains("processInfo.environment") || $0.text.contains("getenv(") }
        #expect(named.map(\.name) == [])
    }

    /// These write and delete in a folder they're told, with all the app has been allowed.
    @Test func theFlagsThatTakeAFolderAreForDebugBuilds() throws {
        var isInDebug = false
        var found = 0
        for line in try text(of: "Sources/Dynotch/App/DynotchApp.swift").split(separator: "\n") {
            let code = line.trimmingCharacters(in: .whitespaces)
            if code == "#if DEBUG" { isInDebug = true }
            if code == "#endif" { isInDebug = false }
            if line.contains("\"--snapshot\"") || line.contains("\"--capture-self-test\"") {
                found += 1
                #expect(isInDebug, "\(code)")
            }
        }
        #expect(found >= 3)
    }

    /// The keychain is only open while a build needs it.
    @Test func aBuildLeavesTheSigningKeychainLocked() throws {
        #expect(try text(of: "scripts/build.sh").contains("trap 'security lock-keychain \"$KEYCHAIN\"' EXIT"))
    }

    /// The updater's script is fixed, and takes nothing from a request or the command line.
    @Test func onlyTheUpdaterStartsAShell() throws {
        let named = try appSources().filter { source in
            ["/bin/sh", "/bin/zsh", "/bin/bash"].contains { source.text.contains("\"\($0)\"") }
        }
        #expect(named.map(\.name) == ["UpdateInstaller.swift"])
    }

    @Test func theCommandIsSignedAsItself() throws {
        let build = try text(of: "scripts/build.sh").split(separator: "\n").map(String.init)
        let command = try #require(build.firstIndex { $0.contains("codesign") && $0.contains("Contents/Helpers/DynotchCommand") })
        let app = try #require(build.firstIndex { $0.contains("codesign") && $0.contains("Dynotch.entitlements") })
        #expect(build[command].contains("--identifier app.dynotch.command"))
        #expect(!build[command].contains("--entitlements"))
        // The app's signature covers what's inside it, so the command has to be signed first.
        #expect(command < app)
        #expect(!build[app].contains("--identifier"))
    }

    /// `Contents/MacOS` would make it part of the app's bundle in the eyes of anything that goes by the path.
    @Test func theCommandSitsApartFromTheAppsBinary() throws {
        let build = try text(of: "scripts/build.sh")
        #expect(build.contains("cp \"$BIN_DIR/DynotchCommand\" \"$STAGE/Contents/Helpers/DynotchCommand\""))
        let script = try text(of: "scripts/dynotch")
        #expect(script.contains("../Helpers/DynotchCommand"))
        #expect(!script.contains("MacOS/Dynotch"))
        #expect(!script.contains("--cli"))
    }
}
