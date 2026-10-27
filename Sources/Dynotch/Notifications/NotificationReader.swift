import Foundation
import SQLite3

/// Reads notifications from Notification Center's database as they're delivered. There's no public
/// API for other apps' notifications. macOS keeps them in a SQLite database (WAL mode) at
/// `~/Library/Group Containers/group.com.apple.usernoted/db2/db`, which needs Full Disk Access.
/// Each notification is a row in `record`: `data` is a property list with the app's bundle ID under
/// `app` and the text under `req` (`titl`, `subt`, `body`), and `delivered_date` is set once it's
/// delivered, in seconds since 2001.
///
/// The database is opened read-only, and its write-ahead log watched for writes. Nothing read is
/// kept: the reader remembers only the delivery time of the newest notification it handed over.
final class NotificationReader: @unchecked Sendable {
    /// What one delivered notification says.
    struct Entry: Sendable {
        let bundleID: String
        let title: String
        let subtitle: String
        let body: String
    }

    enum Problem: Error, Equatable {
        /// Full Disk Access is off, or was turned off.
        case noAccess
        /// The database isn't where macOS used to keep it, or its tables changed.
        case unsupported
    }

    /// The database is busy for a moment; the next change tries again.
    private struct Busy: Error {}

    static let defaultFolder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Group Containers/group.com.apple.usernoted/db2", isDirectory: true)

    let folder: URL
    private var databasePath: String { folder.appendingPathComponent("db").path }
    private var logPath: String { folder.appendingPathComponent("db-wal").path }

    // Everything below is used on `queue` only.
    private let queue = DispatchQueue(label: "app.dynotch.notification-reader", qos: .utility)
    private var connection: OpaquePointer?
    private var openedInode: ino_t = 0
    private var folderSource: DispatchSourceFileSystemObject?
    private var logSource: DispatchSourceFileSystemObject?
    private var logInode: ino_t = 0
    private var isReadScheduled = false
    /// The newest delivery handed over, in seconds since 2001 like the database.
    private var cursor: Double = 0
    /// Rows handed over lately, so one whose delivery date moves again doesn't peek twice.
    private var handedOver: [Int64] = []
    private var handler: (([Entry]) -> Void)?
    private var failure: ((Problem) -> Void)?

    init(folder: URL = NotificationReader.defaultFolder) {
        self.folder = folder
    }

    /// Why the database can't be opened, or nil if it can. Reads nothing from it.
    func problem() -> Problem? {
        let descriptor = open(databasePath, O_RDONLY)
        guard descriptor < 0 else {
            close(descriptor)
            return nil
        }
        // Without Full Disk Access every path in the container fails with EPERM, missing or not.
        return errno == ENOENT ? .unsupported : .noAccess
    }

    /// Starts watching. `handler` gets the notifications delivered since its last call, oldest first;
    /// `failure` says why reading stopped. Both are called on the reader's own queue.
    func start(handler: @escaping ([Entry]) -> Void, failure: @escaping (Problem) -> Void) {
        queue.async { [self] in
            guard self.handler == nil else { return }
            self.handler = handler
            self.failure = failure
            do {
                try openDatabase()
                do {
                    cursor = try newestDelivery() ?? Date.now.timeIntervalSinceReferenceDate
                } catch is Busy {
                    cursor = Date.now.timeIntervalSinceReferenceDate
                }
                try startWatching()
            } catch {
                fail(error as? Problem ?? .unsupported)
            }
        }
    }

    func stop() {
        queue.async { [self] in
            stopWatching()
            closeDatabase()
            handler = nil
            failure = nil
        }
    }

    // MARK: Watching

    /// Watches the WAL, where every new notification is written first, and the folder, which changes
    /// when the WAL is deleted or comes back. FSEvents won't do: it reports a file's changes when
    /// the file is closed, and Notification Center keeps the database open.
    private func startWatching() throws {
        folderSource = try source(for: folder.path, events: [.write, .delete, .rename, .revoke]) { [weak self] events in
            guard let self else { return }
            if !events.isDisjoint(with: [.delete, .rename, .revoke]) {
                fail(.unsupported)
            } else {
                watchLog()
                readSoon()
            }
        }
        watchLog()
    }

    /// Starts watching the WAL, or the new one if it was replaced.
    private func watchLog() {
        var info = stat()
        let inode = stat(logPath, &info) == 0 ? info.st_ino : 0
        guard inode != logInode || (inode != 0 && logSource == nil) else { return }
        logSource?.cancel()
        logSource = nil
        logInode = inode
        guard inode != 0 else { return }
        logSource = try? source(for: logPath, events: [.write, .extend, .delete, .rename, .revoke]) { [weak self] events in
            guard let self else { return }
            if !events.isDisjoint(with: [.delete, .rename, .revoke]) {
                logSource?.cancel()
                logSource = nil
                logInode = 0
            }
            readSoon()
        }
    }

    private func source(for path: String, events: DispatchSource.FileSystemEvent,
                        handler: @escaping (DispatchSource.FileSystemEvent) -> Void) throws -> DispatchSourceFileSystemObject {
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { throw problem() ?? .unsupported }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: events, queue: queue)
        source.setEventHandler { [unowned source] in handler(source.data) }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        return source
    }

    private func stopWatching() {
        folderSource?.cancel()
        folderSource = nil
        logSource?.cancel()
        logSource = nil
        logInode = 0
    }

    /// One read for the handful of writes a notification makes.
    private func readSoon() {
        guard !isReadScheduled else { return }
        isReadScheduled = true
        queue.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.isReadScheduled = false
            self?.readNew()
        }
    }

    /// Hands over what was delivered after the cursor. Only the newest few count, so a backlog
    /// (after waking from sleep, say) doesn't replay.
    private func readNew() {
        guard let handler else { return }
        do {
            if connection == nil || !isStillOpenFile() {
                closeDatabase()
                try openDatabase()
            }
            let statement = try prepare("""
                SELECT record.rec_id, app.identifier, record.data, record.delivered_date FROM record
                LEFT JOIN app ON app.app_id = record.app_id
                WHERE record.delivered_date > ? ORDER BY record.delivered_date DESC LIMIT 8
                """)
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_double(statement, 1, cursor)
            var entries: [Entry] = []
            var newest = cursor
            while try step(statement) {
                newest = max(newest, sqlite3_column_double(statement, 3))
                let row = sqlite3_column_int64(statement, 0)
                guard !handedOver.contains(row) else { continue }
                handedOver = handedOver.suffix(63) + [row]
                let identifier = sqlite3_column_text(statement, 1).map { String(cString: $0) }
                guard let bytes = sqlite3_column_blob(statement, 2) else { continue }
                let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 2)))
                if let entry = Self.entry(bundleID: identifier, data: data) { entries.insert(entry, at: 0) }
            }
            cursor = newest
            if !entries.isEmpty { handler(entries) }
        } catch let problem as Problem {
            fail(problem)
        } catch {
            closeDatabase()
        }
    }

    private func fail(_ problem: Problem) {
        let failure = failure
        stopWatching()
        closeDatabase()
        handler = nil
        self.failure = nil
        failure?(problem)
    }

    // MARK: Database

    private func openDatabase() throws {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(databasePath, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let handle else {
            sqlite3_close(handle)
            throw problem() ?? .unsupported
        }
        sqlite3_busy_timeout(handle, 250)
        connection = handle
        var info = stat()
        openedInode = stat(databasePath, &info) == 0 ? info.st_ino : 0
    }

    private func closeDatabase() {
        sqlite3_close(connection)
        connection = nil
    }

    /// False once the path holds a different file, or can't be seen any more.
    private func isStillOpenFile() -> Bool {
        var info = stat()
        return stat(databasePath, &info) == 0 && info.st_ino == openedInode
    }

    private func newestDelivery() throws -> Double? {
        let statement = try prepare("SELECT max(delivered_date) FROM record")
        defer { sqlite3_finalize(statement) }
        guard try step(statement), sqlite3_column_type(statement, 0) != SQLITE_NULL else { return nil }
        return sqlite3_column_double(statement, 0)
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        let status = sqlite3_prepare_v2(connection, sql, -1, &statement, nil)
        guard status == SQLITE_OK else {
            sqlite3_finalize(statement)
            throw error(for: status)
        }
        return statement
    }

    /// True while there's another row.
    private func step(_ statement: OpaquePointer?) throws -> Bool {
        let status = sqlite3_step(statement)
        if status == SQLITE_ROW { return true }
        if status == SQLITE_DONE { return false }
        throw error(for: status)
    }

    private func error(for status: Int32) -> Error {
        switch status & 0xFF {
        case SQLITE_BUSY, SQLITE_LOCKED:
            return Busy()
        case SQLITE_CANTOPEN, SQLITE_AUTH, SQLITE_PERM:
            if let problem = problem() { return problem }
            return Busy()
        default:
            // Tables or columns that aren't there: a version of macOS this reader doesn't know.
            return problem() ?? .unsupported
        }
    }

    // MARK: Decoding

    /// Decodes a record's `data`. The bundle ID comes from the `app` table, or else from the plist.
    static func entry(bundleID: String?, data: Data) -> Entry? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let bundleID = bundleID ?? plist["app"] as? String else { return nil }
        let request = plist["req"] as? [String: Any] ?? plist
        let entry = Entry(bundleID: bundleID, title: text(request["titl"]), subtitle: text(request["subt"]),
                          body: text(request["body"]))
        return entry.title.isEmpty && entry.subtitle.isEmpty && entry.body.isEmpty ? nil : entry
    }

    /// A field as one line of text.
    private static func text(_ value: Any?) -> String {
        guard let string = value as? String else { return "" }
        return string.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }
}
