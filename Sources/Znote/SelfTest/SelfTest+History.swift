import Foundation

/// Scenario `history` — the SQLite store, against a database `seed.py` wrote
/// in the pre-screenshot schema (no `image_path` column) so opening it also
/// exercises the migration.
extension SelfTest {
    private struct HistorySeed: Decodable {
        let total: Int
        let voice: Int
        let translation: Int
        let needleOutput: String
        let needleOutputRows: Int
        let needleInput: String
        let needleInputRows: Int
        let newestText: String
        let percentRows: Int
        let underscoreRows: Int
    }

    static func runHistory(_ request: Request, _ r: inout Report) {
        let seed: HistorySeed
        do {
            seed = try JSONDecoder().decode(
                HistorySeed.self, from: Data(contentsOf: request.dir.appendingPathComponent("manifest.json")))
        } catch {
            r.errors.append("manifest: \(error)")
            return
        }

        let store = HistoryStore.shared   // opens <dir>/history.sqlite in self-test mode

        // 1. The app sees the seeded rows.
        r.expect("seed: row count", store.count, seed.total)
        guard store.count == seed.total else { return }

        // 2. Old-schema database is usable (fetch selects image_path, so it
        //    returns nothing if the migration didn't add the column).
        var t = Date()
        let all = store.fetch()
        r.step("migration: old schema readable", ok: !all.isEmpty, ms: ms(since: t), ["rows": "\(all.count)"])

        // 3. Listing: capped, newest first.
        r.expect("list: capped at 500", all.count, min(500, seed.total))
        r.expect("list: newest row first", all.first?.outputText, seed.newestText)
        let sorted = zip(all, all.dropFirst()).allSatisfy { $0.timestamp >= $1.timestamp }
        r.step("list: descending by time", ok: sorted)

        // 4. Search.
        t = Date()
        let byOutput = store.fetch(query: seed.needleOutput)
        r.step("search: matches output text", ok: byOutput.count == seed.needleOutputRows
                && byOutput.allSatisfy { $0.outputText.contains(seed.needleOutput) },
               ms: ms(since: t), ["rows": "\(byOutput.count)", "want": "\(seed.needleOutputRows)"])
        let byInput = store.fetch(query: seed.needleInput)
        r.step("search: matches translation source text", ok: byInput.count == seed.needleInputRows
                && byInput.allSatisfy { $0.type == .translation && ($0.inputText ?? "").contains(seed.needleInput) },
               ["rows": "\(byInput.count)", "want": "\(seed.needleInputRows)"])
        r.expect("search: no match → empty", store.fetch(query: "zz-no-such-text-zz").count, 0)
        // "%" is typed by a person, not meant as a wildcard.
        let percent = store.fetch(query: "100%")
        r.step("search: '%' is literal", ok: percent.count == seed.percentRows
                && percent.allSatisfy { $0.outputText.contains("100%") },
               ["rows": "\(percent.count)", "want": "\(seed.percentRows)"])
        let underscore = store.fetch(query: "file_name")
        r.step("search: '_' is literal", ok: underscore.count == seed.underscoreRows
                && underscore.allSatisfy { $0.outputText.contains("file_name") },
               ["rows": "\(underscore.count)", "want": "\(seed.underscoreRows)"])
        r.expect("search: lone backslash matches nothing", store.fetch(query: "\\").count, 0)

        // 5. Type filter.
        let voice = store.fetch(typeFilter: .voice)
        r.step("filter: voice", ok: voice.count == min(500, seed.voice) && voice.allSatisfy { $0.type == .voice },
               ["rows": "\(voice.count)"])
        let translation = store.fetch(typeFilter: .translation)
        r.step("filter: translation", ok: translation.count == min(500, seed.translation)
                && translation.allSatisfy { $0.type == .translation }, ["rows": "\(translation.count)"])
        r.expect("filter: screenshot (none yet)", store.fetch(typeFilter: .screenshot).count, 0)
        r.expect("filter + search combine", store.fetch(query: seed.needleOutput, typeFilter: .translation).count, 0)

        // 6. Writing each record type through the app's own API.
        let media = request.dir.appendingPathComponent("media", isDirectory: true)
        try? FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let shot = media.appendingPathComponent("screenshot-probe.png").path
        let clip = media.appendingPathComponent("recording-probe.mov").path
        FileManager.default.createFile(atPath: shot, contents: Data([0x89, 0x50, 0x4E, 0x47]))
        FileManager.default.createFile(atPath: clip, contents: Data([0x00, 0x00, 0x00, 0x14]))

        store.addVoice(text: "probe voice entry", duration: 3.5)
        var newest = store.fetch().first
        r.step("add: voice", ok: newest?.type == .voice && newest?.outputText == "probe voice entry"
                && newest?.duration == 3.5 && newest?.imagePath == nil)
        let voiceID = newest?.id

        store.addTranslation(input: "probe 原文", output: "probe translation", sourceLang: "zh", targetLang: "en")
        newest = store.fetch().first
        r.step("add: translation", ok: newest?.type == .translation && newest?.inputText == "probe 原文"
                && newest?.outputText == "probe translation" && newest?.sourceLang == "zh" && newest?.targetLang == "en")

        store.addScreenshot(path: shot)
        newest = store.fetch().first
        r.step("add: screenshot", ok: newest?.type == .screenshot && newest?.outputText == "screenshot-probe.png"
                && newest?.imagePath == shot)
        let shotID = newest?.id

        store.addRecording(path: clip, duration: 12.5)
        newest = store.fetch().first
        r.step("add: recording", ok: newest?.type == .recording && newest?.outputText == "recording-probe.mov"
                && newest?.imagePath == clip && newest?.duration == 12.5)
        r.expect("add: count grew by 4", store.count, seed.total + 4)
        r.expect("filter: screenshot (one now)", store.fetch(typeFilter: .screenshot).count, 1)
        r.expect("filter: recording (one now)", store.fetch(typeFilter: .recording).count, 1)

        // 7. Deleting a record removes its media file; deleting a text record
        //    leaves other files alone.
        if let shotID, let voiceID {
            store.delete(id: shotID)
            r.step("delete: screenshot row + its file", ok: store.count == seed.total + 3
                    && !FileManager.default.fileExists(atPath: shot) && FileManager.default.fileExists(atPath: clip))
            store.delete(id: voiceID)
            r.step("delete: text row", ok: store.count == seed.total + 2 && FileManager.default.fileExists(atPath: clip))
        } else {
            r.step("delete: rows to delete were found", ok: false)
        }

        // 7b. Notes, and where a selection was made — columns this old
        //     database didn't have until it was opened.
        let page = SelectionSource(appName: "Google Chrome", bundleID: "com.google.Chrome",
                                   windowTitle: "Probe page title", url: "https://example.com/docs/page")
        store.addNote(text: "the selected words", note: "  why this matters  ", source: page)
        newest = store.fetch().first
        r.step("add: note", ok: newest?.type == .note && newest?.outputText == "the selected words"
                && newest?.note == "why this matters" && newest?.source == page,
               ["note": newest?.note ?? "nil", "source": newest?.source?.label ?? "nil"])
        store.addNote(text: "bookmark only", note: "", source: nil)
        newest = store.fetch().first
        r.step("add: note with nothing written and no source", ok: newest?.type == .note && newest?.note == nil
                && newest?.source == nil && newest?.restoreAction == nil)
        store.addTranslation(input: "probe 原文二", output: "probe two", sourceLang: "zh", targetLang: "en", source: page)
        r.expect("add: translation remembers where it was made", store.fetch().first?.source, page)
        r.expect("filter: note", store.fetch(typeFilter: .note).count, 2)
        r.expect("search: matches what the note says", store.fetch(query: "why this matters").first?.outputText, "the selected words")
        r.expect("search: matches the source's window title", store.fetch(query: "Probe page title").count, 2)
        r.expect("search: matches the source's address", store.fetch(query: "example.com/docs").count, 2)
        r.step("old rows have no source", ok: store.fetch(typeFilter: .voice).allSatisfy { $0.source == nil && $0.note == nil })

        // 8. Clear all.
        t = Date()
        store.deleteAll()
        r.step("clear all: rows and media gone", ok: store.count == 0 && !FileManager.default.fileExists(atPath: clip),
               ms: ms(since: t))
        r.expect("clear all: list is empty", store.fetch().count, 0)
    }
}
