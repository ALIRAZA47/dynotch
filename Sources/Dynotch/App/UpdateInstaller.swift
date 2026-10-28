import AppKit
import Security

/// Installs a release over this copy of Dynotch: downloads its zip, checks that the app inside is
/// Dynotch, the version announced and newer, and signed with the same certificate as this copy,
/// puts it in this copy's place and opens it. The certificate is what keeps anything else out:
/// only the key that signed this copy can make an app that passes. Settings, notes, the Tray and
/// the permissions given to Dynotch stay, as macOS sees the same app.
@MainActor
final class UpdateInstaller: ObservableObject {
    static let shared = UpdateInstaller()

    enum State: Equatable {
        case idle
        /// How much has arrived, when the size is known.
        case downloading(Double?)
        case verifying
        case installing
        case failed(String)
    }

    @Published private(set) var state = State.idle

    private init() {}

    /// This copy can replace itself: it's signed with a certificate, which an update has to match (an
    /// ad hoc build has none), and it isn't running from somewhere read-only, like a disk image or the
    /// copy macOS runs a downloaded app from until it's moved (App Translocation).
    var canInstall: Bool {
        Self.ownRequirement() != nil && Self.canReplace(Bundle.main.bundleURL)
    }

    var isBusy: Bool {
        switch state {
        case .downloading, .verifying, .installing: true
        case .idle, .failed: false
        }
    }

    func install(_ release: UpdateChecker.Release) {
        guard !isBusy, let archive = release.archive else { return }
        Task { await run(release, archive: archive) }
    }

    private func run(_ release: UpdateChecker.Release, archive: URL) async {
        let target = Bundle.main.bundleURL
        var staging: URL?
        do {
            guard archive.scheme == "https" else { throw InstallError.insecure }
            guard let requirement = Self.ownRequirement() else { throw InstallError.unsigned }
            // Next to the app, so the swap is a rename on the same volume.
            let folder = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                     appropriateFor: target, create: true)
            staging = folder
            state = .downloading(nil)
            let zip = try await Downloader(destination: folder.appendingPathComponent("update.zip")) { fraction in
                Task { @MainActor in
                    let installer = UpdateInstaller.shared
                    if case .downloading = installer.state { installer.state = .downloading(fraction) }
                }
            }.download(archive)
            state = .verifying
            let app = try await Self.prepare(zip, in: folder, version: release.version, requirement: requirement)
            state = .installing
            try Self.swap(app, into: target)
            try? FileManager.default.removeItem(at: folder)
            Self.relaunch(target)
        } catch {
            if let staging { try? FileManager.default.removeItem(at: staging) }
            state = .failed(Self.describe(error))
        }
    }

    // MARK: Steps

    /// Unpacks `zip` in `folder` and checks the app inside: Dynotch, at `version` and newer than
    /// `current`, signed to meet `requirement`. Returns the app, without the download mark, so its
    /// first launch doesn't stop at Gatekeeper.
    static func prepare(_ zip: URL, in folder: URL, version: String, requirement: SecRequirement,
                        bundleID: String? = Bundle.main.bundleIdentifier,
                        current: String = UpdateChecker.currentVersion) async throws -> URL {
        let unpacked = folder.appendingPathComponent("unpacked", isDirectory: true)
        guard await Shell.run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path]).status == 0 else {
            throw InstallError.unpack
        }
        let apps = try FileManager.default.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "app" }
        guard apps.count == 1, let app = apps.first,
              let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any] else {
            throw InstallError.notDynotch
        }
        guard info["CFBundleIdentifier"] as? String == bundleID else { throw InstallError.notDynotch }
        let found = info["CFBundleShortVersionString"] as? String ?? ""
        guard UpdateChecker.compare(found, version) == .orderedSame, UpdateChecker.isNewer(found, than: current) else {
            throw InstallError.wrongVersion(found)
        }
        removeQuarantine(from: app)
        guard isSigned(app, meeting: requirement) else { throw InstallError.badSignature }
        return app
    }

    /// Puts `app` where `target` is, swapping the two in one step where the volume allows it.
    static func swap(_ app: URL, into target: URL) throws {
        _ = try FileManager.default.replaceItemAt(target, withItemAt: app, backupItemName: nil,
                                                  options: .usingNewMetadataOnly)
    }

    /// Quits, and opens `app` once this process has gone, telling it it's been updated.
    private static func relaunch(_ app: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$2\" --args --updated",
                             "sh", String(getpid()), app.path]
        try? process.run()
        NSApp.terminate(nil)
    }

    // MARK: Signatures

    /// What an update has to meet: this copy's designated requirement, which names its bundle
    /// identifier and the certificate that signed it. Nil for an ad hoc or unsigned build.
    static func ownRequirement() -> SecRequirement? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        return designatedRequirement(of: staticCode)
    }

    /// The designated requirement of code signed with a certificate.
    static func designatedRequirement(of code: SecStaticCode) -> SecRequirement? {
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: UInt32(kSecCSSigningInformation)), &info) == errSecSuccess,
              let certificates = (info as? [String: Any])?[kSecCodeInfoCertificates as String] as? [SecCertificate],
              !certificates.isEmpty else { return nil }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess else { return nil }
        return requirement
    }

    /// Whether every part of `app`, nested code included, is intact and signed to meet `requirement`.
    static func isSigned(_ app: URL, meeting requirement: SecRequirement) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { return false }
        let flags = SecCSFlags(rawValue: UInt32(kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate))
        return SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
    }

    // MARK: Helpers

    /// The bundle and the folder it's in can be written, and it isn't a translocated copy.
    static func canReplace(_ target: URL) -> Bool {
        let files = FileManager.default
        return !target.path.contains("/AppTranslocation/")
            && files.isWritableFile(atPath: target.path)
            && files.isWritableFile(atPath: target.deletingLastPathComponent().path)
    }

    private static func removeQuarantine(from app: URL) {
        let inside = FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        for url in [app] + inside {
            removexattr(url.path, "com.apple.quarantine", XATTR_NOFOLLOW)
        }
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case InstallError.insecure: "The update's address isn't secure, so it wasn't downloaded."
        case InstallError.unsigned: "This copy of Dynotch isn't signed, so there's nothing to check an update against."
        case InstallError.status(let code): "The download failed (HTTP \(code))."
        case InstallError.unpack: "The download couldn't be unpacked."
        case InstallError.notDynotch: "The download isn't Dynotch, so it wasn't installed."
        case InstallError.wrongVersion(let found):
            "The download is version \(found.isEmpty ? "unknown" : found), not the one announced, so it wasn't installed."
        case InstallError.badSignature: "The download isn't signed with this copy's certificate, so it wasn't installed."
        case let error as URLError where error.code == .notConnectedToInternet: "You're offline. Try again once you're connected."
        case is URLError: "The download didn't finish. Check your connection and try again."
        case let error as CocoaError where error.code == .fileWriteNoPermission:
            "Dynotch can't replace itself where it is. Download the update and swap it in Applications instead."
        default: error.localizedDescription
        }
    }
}

private enum InstallError: Error {
    case insecure, unsigned, status(Int), unpack, notDynotch, wrongVersion(String), badSignature
}

/// Downloads one file into place, reporting how much has arrived.
private final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let progress: @Sendable (Double?) -> Void
    private var continuation: CheckedContinuation<URL, Error>?

    init(destination: URL, progress: @escaping @Sendable (Double?) -> Void) {
        self.destination = destination
        self.progress = progress
    }

    func download(_ url: URL) async throws -> URL {
        var request = URLRequest(url: url)
        request.setValue("Dynotch/\(UpdateChecker.currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 60
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
            session.downloadTask(with: request).resume()
            session.finishTasksAndInvalidate()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progress(totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : nil)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            finish(.failure(InstallError.status(http.statusCode)))
            return
        }
        // The file at `location` is gone once this returns.
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            finish(.success(destination))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
    }

    private func finish(_ result: Result<URL, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}
