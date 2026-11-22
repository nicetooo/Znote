import Foundation
import CSQLite

// MARK: - History Record

struct HistoryRecord {
    let id: Int64
    let type: HistoryType
    let inputText: String?      // original text (for translation), nil for voice
    let outputText: String      // transcribed or translated text, or filename for screenshot
    let sourceLang: String?
    let targetLang: String?
    let timestamp: Date
    let duration: Double?       // recording duration in seconds (for voice)
    let imagePath: String?      // absolute PNG path for screenshot type, nil otherwise
    var note: String? = nil     // what the user wrote about the selection (note type)
    /// Where the selection was made (notes and translations), nil if unknown.
    var source: SelectionSource? = nil

    /// What "go back to where this came from" would do, or nil.
    var restoreAction: SourceRestorer.Action? {
        guard let source else { return nil }
        return SourceRestorer.action(for: source, text: type == .translation ? (inputText ?? outputText) : outputText)
    }

    var displayText: String {
        switch type {
        case .voice:
            return outputText
        case .translation:
            if let input = inputText { return "\(input)\n→ \(outputText)" }
            return outputText
        case .screenshot:
            return L("history.row.screenshot_prefix", outputText)  // outputText holds filename
        case .recording:
            return L("history.row.recording_prefix", outputText)   // outputText holds filename
        case .note:
            // The user's own words first; the selection they are about, quoted.
            let quote = "“\(outputText)”"
            if let note, !note.isEmpty { return "\(note)\n\(quote)" }
            return quote
        }
    }

    var copyText: String {
        guard type == .note else { return outputText }
        // A note is copied whole: what was written, what it is about, where.
        var parts: [String] = []
        if let note, !note.isEmpty { parts.append(note) }
        parts.append(outputText)
        if let url = source?.webURL?.absoluteString ?? source?.fileURL?.path { parts.append(url) }
        return parts.joined(separator: "\n")
    }
}

enum HistoryType: String {
    case voice = "voice"
    case translation = "translation"
    case screenshot = "screenshot"
    case recording = "recording"
    case note = "note"
}

enum HistoryTypeFilter: Int {
    case all = 0
    case voice = 1
    case translation = 2
    case screenshot = 3
    case recording = 4
    case note = 5

    /// nil → show everything; otherwise restrict to this type.
    var historyType: HistoryType? {
        switch self {
        case .all: return nil
        case .voice: return .voice
        case .translation: return .translation
        case .screenshot: return .screenshot
        case .recording: return .recording
        case .note: return .note
        }
    }
}

// MARK: - History Store (SQLite)

class HistoryStore {
    static let shared = HistoryStore()
    private var db: OpaquePointer?
    private let SQLITE_TRANSIENT_PTR = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init() {
        openDatabase()
        createTable()
    }

    deinit {
        if let db = db {
            sqlite3_close(db)
        }
    }

    // MARK: - Database Setup

    private func openDatabase() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        // A self-test run works on its own database, never the user's history.
        let appDir = SelfTest.request?.dir ?? appSupport.appendingPathComponent("Znote")
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        let dbPath = appDir.appendingPathComponent("history.sqlite").path

        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            let err = db != nil ? String(cString: sqlite3_errmsg(db)!) : "unknown"
            log("HistoryStore: failed to open DB — \(err)")
        } else {
            log("HistoryStore: opened \(dbPath)")
        }
    }

    private func createTable() {
        let sql = """
            CREATE TABLE IF NOT EXISTS history (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                type TEXT NOT NULL,
                input_text TEXT,
                output_text TEXT NOT NULL,
                source_lang TEXT,
                target_lang TEXT,
                timestamp REAL NOT NULL,
                duration REAL,
                image_path TEXT
            );
            CREATE INDEX IF NOT EXISTS idx_history_timestamp ON history(timestamp);
            """
        var errMsg: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &errMsg) != SQLITE_OK {
            let err = errMsg != nil ? String(cString: errMsg!) : "unknown"
            log("HistoryStore: create table failed — \(err)")
            sqlite3_free(errMsg)
        }
        // Migration for DBs created before image_path column existed.
        // sqlite throws "duplicate column" if it already exists — we swallow that.
        sqlite3_exec(db, "ALTER TABLE history ADD COLUMN image_path TEXT", nil, nil, nil)
        // Notes, and where a selection was made — same approach.
        for column in ["note", "source_app", "source_bundle", "source_title", "source_url"] {
            sqlite3_exec(db, "ALTER TABLE history ADD COLUMN \(column) TEXT", nil, nil, nil)
        }
    }

    // MARK: - Insert

    func addVoice(text: String, duration: Double? = nil) {
        insert(type: .voice, inputText: nil, outputText: text,
               sourceLang: nil, targetLang: nil, duration: duration, imagePath: nil)
        log("HistoryStore: saved voice record")
    }

    func addTranslation(input: String, output: String, sourceLang: String?, targetLang: String?,
                        source: SelectionSource? = nil) {
        insert(type: .translation, inputText: input, outputText: output,
               sourceLang: sourceLang, targetLang: targetLang, duration: nil, imagePath: nil, source: source)
        log("HistoryStore: saved translation record")
    }

    /// Save a note about a selection. `note` may be empty: the selection and
    /// where it was made are worth keeping on their own.
    func addNote(text: String, note: String, source: SelectionSource?) {
        let written = note.trimmingCharacters(in: .whitespacesAndNewlines)
        insert(type: .note, inputText: nil, outputText: text,
               sourceLang: nil, targetLang: nil, duration: nil, imagePath: nil,
               note: written.isEmpty ? nil : written, source: source)
        log("HistoryStore: saved note record")
    }

    /// Save a screenshot record. `path` is the absolute PNG path on disk.
    /// `outputText` is set to the filename (no path) for compact display in history.
    func addScreenshot(path: String) {
        let filename = (path as NSString).lastPathComponent
        insert(type: .screenshot, inputText: nil, outputText: filename,
               sourceLang: nil, targetLang: nil, duration: nil, imagePath: path)
        log("HistoryStore: saved screenshot record (\(filename))")
    }

    /// Save a screen recording record. `path` is the absolute .mov path on disk.
    /// We reuse the `image_path` column (semantic: media file on disk) and
    /// distinguish video from image via the `type` field. Optional `duration`
    /// is the recording length in seconds — handy for UI display.
    func addRecording(path: String, duration: Double? = nil) {
        let filename = (path as NSString).lastPathComponent
        insert(type: .recording, inputText: nil, outputText: filename,
               sourceLang: nil, targetLang: nil, duration: duration, imagePath: path)
        log("HistoryStore: saved recording record (\(filename))")
    }

    private func insert(type: HistoryType, inputText: String?, outputText: String,
                        sourceLang: String?, targetLang: String?, duration: Double?,
                        imagePath: String?, note: String? = nil, source: SelectionSource? = nil) {
        let sql = """
            INSERT INTO history (type, input_text, output_text, source_lang, target_lang, timestamp, duration, image_path,
                                 note, source_app, source_bundle, source_title, source_url)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            log("HistoryStore: insert prepare failed")
            return
        }
        defer { sqlite3_finalize(stmt) }

        bindText(stmt, 1, type.rawValue)
        bindText(stmt, 2, inputText)
        bindText(stmt, 3, outputText)
        bindText(stmt, 4, sourceLang)
        bindText(stmt, 5, targetLang)
        sqlite3_bind_double(stmt, 6, Date().timeIntervalSince1970)
        if let d = duration {
            sqlite3_bind_double(stmt, 7, d)
        } else {
            sqlite3_bind_null(stmt, 7)
        }
        bindText(stmt, 8, imagePath)
        bindText(stmt, 9, note)
        bindText(stmt, 10, source?.appName)
        bindText(stmt, 11, source?.bundleID)
        bindText(stmt, 12, source?.windowTitle)
        bindText(stmt, 13, source?.url)

        if sqlite3_step(stmt) != SQLITE_DONE {
            log("HistoryStore: insert step failed")
        }
    }

    // MARK: - Query

    func fetch(query: String? = nil, typeFilter: HistoryTypeFilter = .all) -> [HistoryRecord] {
        var conditions: [String] = []
        var textParams: [String] = []

        if let q = query, !q.isEmpty {
            // LIKE reads % and _ as wildcards; the user typed them as plain text.
            let literal = q
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%")
                .replacingOccurrences(of: "_", with: "\\_")
            // A note is found by what it says and by where it was taken.
            let columns = ["output_text", "input_text", "note", "source_title", "source_url"]
            conditions.append("(" + columns.map { "\($0) LIKE ? ESCAPE '\\'" }.joined(separator: " OR ") + ")")
            textParams.append(contentsOf: Array(repeating: "%\(literal)%", count: columns.count))
        }
        if let type = typeFilter.historyType {
            conditions.append("type = ?")
            textParams.append(type.rawValue)
        }

        var sql = """
            SELECT id, type, input_text, output_text, source_lang, target_lang, timestamp, duration, image_path,
                   note, source_app, source_bundle, source_title, source_url FROM history
            """
        if !conditions.isEmpty {
            sql += " WHERE " + conditions.joined(separator: " AND ")
        }
        sql += " ORDER BY timestamp DESC LIMIT 500"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            log("HistoryStore: fetch prepare failed")
            return []
        }
        defer { sqlite3_finalize(stmt) }

        var paramIdx: Int32 = 1
        for tp in textParams {
            bindText(stmt, paramIdx, tp)
            paramIdx += 1
        }

        var records: [HistoryRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let typeStr = columnText(stmt, 1) ?? "voice"
            let type = HistoryType(rawValue: typeStr) ?? .voice
            let inputText = columnText(stmt, 2)
            let outputText = columnText(stmt, 3) ?? ""
            let sourceLang = columnText(stmt, 4)
            let targetLang = columnText(stmt, 5)
            let timestamp = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6))
            let duration: Double? = sqlite3_column_type(stmt, 7) != SQLITE_NULL
                ? sqlite3_column_double(stmt, 7) : nil
            let imagePath = columnText(stmt, 8)
            let source = SelectionSource(appName: columnText(stmt, 10), bundleID: columnText(stmt, 11),
                                         windowTitle: columnText(stmt, 12), url: columnText(stmt, 13))

            records.append(HistoryRecord(
                id: id, type: type, inputText: inputText, outputText: outputText,
                sourceLang: sourceLang, targetLang: targetLang,
                timestamp: timestamp, duration: duration, imagePath: imagePath,
                note: columnText(stmt, 9), source: source.isEmpty ? nil : source
            ))
        }
        return records
    }

    // MARK: - Delete

    func delete(id: Int64) {
        // Look up image_path first so we can delete the file on disk too.
        let imagePath = lookupImagePath(id: id)

        let sql = "DELETE FROM history WHERE id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, id)
        sqlite3_step(stmt)
        log("HistoryStore: deleted record \(id)")

        if let p = imagePath {
            try? FileManager.default.removeItem(atPath: p)
            log("HistoryStore: removed screenshot file \(p)")
        }
    }

    func deleteAll() {
        // Collect screenshot files first so we can remove them from disk.
        var paths: [String] = []
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT image_path FROM history WHERE image_path IS NOT NULL", -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let p = columnText(stmt, 0) { paths.append(p) }
            }
        }
        sqlite3_finalize(stmt)

        sqlite3_exec(db, "DELETE FROM history", nil, nil, nil)
        log("HistoryStore: deleted all records")

        for p in paths {
            try? FileManager.default.removeItem(atPath: p)
        }
        if !paths.isEmpty { log("HistoryStore: removed \(paths.count) screenshot file(s)") }
    }

    private func lookupImagePath(id: Int64) -> String? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT image_path FROM history WHERE id = ?", -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, id)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return columnText(stmt, 0)
    }

    var count: Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM history", -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
    }

    // MARK: - SQLite Helpers

    private func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value = value {
            sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT_PTR)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private func columnText(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL,
              let ptr = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: ptr)
    }
}
