import Foundation
import Security
import Testing
@testable import Dynotch

/// What the updater takes and refuses. These sign with `codesign --sign -`, which takes no key or
/// keychain: the signature's identifier stands in for a certificate, as something a requirement can
/// name. (A code hash won't do: `/usr/bin/true` is universal, and each architecture has its own.)
@MainActor
struct UpdateInstallerTests {
    private let identifier = "app.dynotch.updatertest"

    private func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("UpdateInstallerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Signs what's at `url`, and fails the test if it can't.
    private func sign(_ url: URL, as signer: String) async {
        let signed = await Shell.run("/usr/bin/codesign", ["--force", "--sign", "-", "--identifier", signer,
                                                           "--timestamp=none", url.path])
        #expect(signed.status == 0)
    }

    /// A small app with a helper inside, as Dynotch has, signed as `signer`.
    private func app(in folder: URL, id: String? = nil, version: String = "2.0.0", signer: String = "ours") async throws -> URL {
        let app = folder.appendingPathComponent("Dynotch.app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        let files = FileManager.default
        for name in ["MacOS", "Helpers", "Resources"] {
            try files.createDirectory(at: contents.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try files.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: contents.appendingPathComponent("MacOS/Dynotch"))
        try files.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: contents.appendingPathComponent("Helpers/Helper"))
        try Data("a resource".utf8).write(to: contents.appendingPathComponent("Resources/resource"))
        let info: [String: Any] = ["CFBundleIdentifier": id ?? identifier, "CFBundleExecutable": "Dynotch",
                                   "CFBundleShortVersionString": version, "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        await sign(contents.appendingPathComponent("Helpers/Helper"), as: "helper")
        await sign(app, as: signer)
        return app
    }

    /// A requirement only something signed as `signer` meets.
    private func signed(as signer: String) throws -> SecRequirement {
        try #require(UpdateInstaller.requirements(from: ["identifier \"\(signer)\""]).first)
    }

    /// `app` in a zip, in a folder of its own, as the download would be.
    private func zip(_ app: URL) async throws -> URL {
        let zip = try folder().appendingPathComponent("update.zip")
        let made = await Shell.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", app.path, zip.path])
        #expect(made.status == 0)
        return zip
    }

    private func prepare(_ zip: URL, requirements: [SecRequirement], version: String = "2.0.0",
                         current: String = "1.0.0") async throws -> URL {
        try await UpdateInstaller.prepare(zip, in: zip.deletingLastPathComponent(), version: version,
                                          requirements: requirements, bundleID: identifier, current: current)
    }

    @Test func takesAnUpdateThatMeetsThisCopysOwnRequirement() async throws {
        let zip = try await zip(try await app(in: try folder()))
        let prepared = try await prepare(zip, requirements: [try signed(as: "ours")])
        #expect(prepared.lastPathComponent == "Dynotch.app")
    }

    @Test func takesAnUpdateThatMeetsOnlyASuccessor() async throws {
        let zip = try await zip(try await app(in: try folder(), signer: "next"))
        let prepared = try await prepare(zip, requirements: [try signed(as: "ours"), try signed(as: "next")])
        #expect(prepared.lastPathComponent == "Dynotch.app")
    }

    @Test func refusesAnUpdateThatMeetsNeither() async throws {
        let zip = try await zip(try await app(in: try folder(), signer: "someone else"))
        let requirements = [try signed(as: "ours"), try signed(as: "next")]
        await #expect(throws: InstallError.badSignature) {
            try await prepare(zip, requirements: requirements)
        }
    }

    @Test func refusesEverythingWithNothingToMeet() async throws {
        let zip = try await zip(try await app(in: try folder()))
        await #expect(throws: InstallError.badSignature) {
            try await prepare(zip, requirements: [])
        }
    }

    @Test func refusesAnAppChangedAfterSigning() async throws {
        let app = try await app(in: try folder())
        let requirement = try signed(as: "ours")
        #expect(UpdateInstaller.isSigned(app, meeting: requirement))
        try Data("changed".utf8).write(to: app.appendingPathComponent("Contents/Resources/resource"))
        let zip = try await zip(app)
        await #expect(throws: InstallError.badSignature) {
            try await prepare(zip, requirements: [requirement])
        }
    }

    @Test func refusesAnAppWhoseHelperChangedAfterSigning() async throws {
        let app = try await app(in: try folder())
        let requirement = try signed(as: "ours")
        #expect(UpdateInstaller.isSigned(app, meeting: requirement))
        try Data("changed".utf8).write(to: app.appendingPathComponent("Contents/Helpers/Helper"))
        let zip = try await zip(app)
        await #expect(throws: InstallError.badSignature) {
            try await prepare(zip, requirements: [requirement])
        }
    }

    @Test func aSuccessorDoesntLoosenTheOtherChecks() async throws {
        let requirement = try signed(as: "next")
        let other = try await zip(try await app(in: try folder(), id: "app.dynotch.somethingelse", signer: "next"))
        await #expect(throws: InstallError.notDynotch) {
            try await prepare(other, requirements: [requirement])
        }

        let zip = try await zip(try await app(in: try folder(), signer: "next"))
        await #expect(throws: InstallError.wrongVersion("2.0.0")) {
            try await prepare(zip, requirements: [requirement], version: "2.1.0")
        }
        await #expect(throws: InstallError.wrongVersion("2.0.0")) {
            try await prepare(zip, requirements: [requirement], current: "2.0.0")
        }
    }

    @Test func anAdHocAppCantMeetACertificate() async throws {
        let app = try await app(in: try folder())
        let leaf = "identifier \"\(identifier)\" and certificate leaf = H\"\(String(repeating: "0", count: 40))\""
        let certificate = try #require(UpdateInstaller.requirements(from: [leaf]).first)
        #expect(!UpdateInstaller.isSigned(app, meeting: certificate))
    }

    @Test func textThatIsntARequirementIsLeftOut() {
        #expect(UpdateInstaller.requirements(from: ["certificate leaf = "]).isEmpty)
    }

    /// One bad character here would leave copies unable to follow a move, so check before a release.
    @Test func successorsNameThisAppAndOneCertificate() throws {
        let form = try Regex("^identifier \"app\\.dynotch\\.Dynotch\" and certificate leaf = H\"[0-9a-f]{40}\"$")
        for successor in UpdateInstaller.successors {
            #expect(successor.wholeMatch(of: form) != nil)
            #expect(UpdateInstaller.requirements(from: [successor]).count == 1)
        }
    }
}
