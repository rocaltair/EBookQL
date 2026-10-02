//
//  ReadingPositionStore.swift
//  EBookQLKit
//
//  "Where was I" per book, shared by every format.
//
//  SQLite rather than a JSON file because several Quick Look extension instances can
//  be alive at once - one per preview - and a whole-file rewrite from a stale instance
//  silently clobbered the other one's records. WAL plus row-level updates also keep
//  writes O(1) as the history grows, and Quick Look kills the extension process every
//  time the panel closes, so the writes have to be durable without a clean shutdown.
//
//  The columns are the union of what both reference projects kept: the position
//  (anchor + section offset + fraction, plus a raw scroll fallback) and the history
//  fields that a "recently read" list would need.
//

import Foundation
import SQLite3
import os.log

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public final class ReadingPositionStore {

    public static let shared = ReadingPositionStore()

    private let lock = NSLock()
    private let log = OSLog(subsystem: "com.rocaltair.EBookQL", category: "Positions")
    private var database: OpaquePointer?
    private var storesSincePrune = 0
    private static let keepBooks = 5000
    private static let pruneEvery = 200

    public init() {}

    /// Inside the extension's own container:
    /// `~/Library/Containers/<preview-bundle-id>/Data/Library/Application Support/EBookQL/positions.sqlite3`
    public var databasePath: String? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return base.appendingPathComponent("EBookQL", isDirectory: true)
            .appendingPathComponent("positions.sqlite3").path
    }

    // MARK: - Reading

    /// Keyed by path; the stored file size acts as a sanity check so a replaced file at
    /// the same path does not inherit the previous book's position.
    public func position(for url: URL, size: Int?) -> ReadingPosition? {
        lock.lock()
        defer { lock.unlock() }
        guard let db = openLocked() else { return nil }

        let sql = "SELECT anchor, section_offset, fraction, scroll_y, size, updated FROM positions WHERE path = ? LIMIT 1;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, (key(for: url) as NSString).utf8String, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }

        if let size, sqlite3_column_type(statement, 4) != SQLITE_NULL,
           Int(sqlite3_column_int64(statement, 4)) != size {
            return nil
        }
        return ReadingPosition(
            anchor: sqlite3_column_text(statement, 0).map { String(cString: $0) },
            sectionOffset: sqlite3_column_double(statement, 1),
            fraction: sqlite3_column_double(statement, 2),
            scrollY: sqlite3_column_double(statement, 3),
            updated: sqlite3_column_double(statement, 5)
        )
    }

    /// Counts an open and remembers the book's identity. Called once the backend has
    /// parsed, because that is when the title and author are known.
    public func noteOpened(_ url: URL, title: String?, author: String?, size: Int?) {
        lock.lock()
        defer { lock.unlock() }
        guard let db = openLocked() else { return }

        let now = Date().timeIntervalSince1970
        let sql = """
        INSERT INTO positions (path, title, author, size, opens, first_read, last_read, updated)
        VALUES (?, ?, ?, ?, 1, ?, ?, ?)
        ON CONFLICT(path) DO UPDATE SET
            title = COALESCE(excluded.title, positions.title),
            author = COALESCE(excluded.author, positions.author),
            size = excluded.size,
            opens = positions.opens + 1,
            last_read = excluded.last_read,
            updated = excluded.updated;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, (key(for: url) as NSString).utf8String, -1, SQLITE_TRANSIENT)
        bind(statement, 2, title)
        bind(statement, 3, author)
        bind(statement, 4, size)
        sqlite3_bind_double(statement, 5, now)
        sqlite3_bind_double(statement, 6, now)
        sqlite3_bind_double(statement, 7, now)
        guard sqlite3_step(statement) == SQLITE_DONE else { return }
        pruneIfNeeded(db)
    }

    public func store(_ position: ReadingPosition, for url: URL, size: Int?) {
        lock.lock()
        defer { lock.unlock() }
        guard let db = openLocked() else { return }

        let sql = """
        INSERT INTO positions (path, anchor, section_offset, fraction, scroll_y, size, last_read, updated)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(path) DO UPDATE SET
            anchor = excluded.anchor,
            section_offset = excluded.section_offset,
            fraction = excluded.fraction,
            scroll_y = excluded.scroll_y,
            size = excluded.size,
            last_read = excluded.last_read,
            updated = excluded.updated;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }

        let now = position.updated > 0 ? position.updated : Date().timeIntervalSince1970
        sqlite3_bind_text(statement, 1, (key(for: url) as NSString).utf8String, -1, SQLITE_TRANSIENT)
        bind(statement, 2, position.anchor)
        sqlite3_bind_double(statement, 3, position.sectionOffset)
        sqlite3_bind_double(statement, 4, position.fraction)
        sqlite3_bind_double(statement, 5, position.scrollY)
        bind(statement, 6, size)
        sqlite3_bind_double(statement, 7, now)
        sqlite3_bind_double(statement, 8, now)
        guard sqlite3_step(statement) == SQLITE_DONE else { return }
        pruneIfNeeded(db)
    }

    // MARK: - Internals

    /// Caller holds `lock`.
    private func openLocked() -> OpaquePointer? {
        if let database { return database }
        guard let path = databasePath else { return nil }

        do {
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: path).deletingLastPathComponent(),
                withIntermediateDirectories: true)
        } catch {
            return nil
        }

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let handle else { return nil }
        database = handle

        sqlite3_exec(handle, "PRAGMA journal_mode=WAL;", nil, nil, nil)
        sqlite3_exec(handle, "PRAGMA synchronous=NORMAL;", nil, nil, nil)
        sqlite3_exec(handle, "PRAGMA journal_size_limit=1048576;", nil, nil, nil)
        sqlite3_exec(handle, """
        CREATE TABLE IF NOT EXISTS positions (
            path TEXT PRIMARY KEY,
            title TEXT,
            author TEXT,
            size INTEGER,
            anchor TEXT,
            section_offset REAL NOT NULL DEFAULT 0,
            fraction REAL NOT NULL DEFAULT 0,
            scroll_y REAL NOT NULL DEFAULT 0,
            opens INTEGER NOT NULL DEFAULT 0,
            first_read REAL NOT NULL DEFAULT 0,
            last_read REAL NOT NULL DEFAULT 0,
            updated REAL NOT NULL DEFAULT 0
        );
        """, nil, nil, nil)
        return handle
    }

    private func pruneIfNeeded(_ db: OpaquePointer) {
        storesSincePrune += 1
        guard storesSincePrune >= Self.pruneEvery else { return }
        storesSincePrune = 0
        // Keeps the table bounded without rewriting everything.
        sqlite3_exec(db, """
        DELETE FROM positions WHERE path NOT IN (
            SELECT path FROM positions ORDER BY updated DESC LIMIT \(Self.keepBooks)
        );
        """, nil, nil, nil)
    }

    private func bind(_ statement: OpaquePointer?, _ index: Int32, _ value: String?) {
        guard let value, !value.isEmpty else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_text(statement, index, (value as NSString).utf8String, -1, SQLITE_TRANSIENT)
    }

    private func bind(_ statement: OpaquePointer?, _ index: Int32, _ value: Int?) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_int64(statement, index, Int64(value))
    }

    private func key(for url: URL) -> String { url.standardizedFileURL.path }
}
