import Foundation
import WhisperKit

/// Scenario `voice` — the WAV files `seed.py` synthesized, through the real
/// WhisperService (model load, decoding, hallucination filter, language
/// verification, Chinese conversion).
extension SelfTest {
    private struct VoiceManifest: Decodable {
        let model: String
        let languages: [String]
        let cases: [VoiceCase]
    }

    private struct VoiceCase: Decodable {
        let id: String
        let audio: String
        let spoken: String
        let translate: Bool
        /// Recognition languages for this case only; nil = the manifest default.
        let languages: [String]?
        let expectEndsWith: String?
        let expectContains: [String]
        let mustNotContain: [String]
        let mustNotEndWith: [String]
        /// Whether the language check is expected to force a second pass.
        let expectRetry: Bool
        /// Skip the text assertions (used where only the retry matters).
        let anyText: Bool
        /// Also played back in real time through the live-dictation loop.
        let live: Bool
    }

    static func runVoice(_ request: Request, _ r: inout Report) async {
        // 1. Seed data is where the runner said it would be.
        let manifest: VoiceManifest
        do {
            manifest = try JSONDecoder().decode(
                VoiceManifest.self, from: Data(contentsOf: request.dir.appendingPathComponent("manifest.json")))
        } catch {
            r.errors.append("manifest: \(error)")
            return
        }
        let missing = manifest.cases.filter { !FileManager.default.fileExists(atPath: $0.audio) }.map(\.id)
        let seeded = !manifest.cases.isEmpty && missing.isEmpty
        r.step("seed", ok: seeded, ["cases": "\(manifest.cases.count)", "missingAudio": missing.joined(separator: ",")])
        guard seeded else { return }

        // Settings come from the manifest, into the isolated store.
        Settings.shared.whisperModel = manifest.model
        Settings.shared.selectedLanguages = manifest.languages
        let model = Settings.shared.whisperModel
        r.env["model"] = model
        r.env["languages"] = manifest.languages.joined(separator: ",")

        // 2. Never let a test run kick off a multi-GB model download.
        let cached = Settings.cachedModelNames().contains(model)
        r.step("model-cached", ok: cached, ["model": model])
        guard cached else { return }

        // 3. Load.
        let whisper = WhisperService()
        var t = Date()
        let loaded = await whisper.loadModel(model)
        r.step("model-load", ok: loaded, ms: ms(since: t), ["model": model])
        guard loaded else { return }

        // 4. Each case through the real transcription path.
        for c in manifest.cases {
            if c.translate && !WhisperService.supportsTranslate(model) {
                // The app refuses to start a translate recording on such a model.
                r.step(c.id, ok: true, ["skipped": "model has no translate task"])
                continue
            }
            Settings.shared.selectedLanguages = c.languages ?? manifest.languages
            let retriesBefore = whisper.languageRetryCount
            t = Date()
            let text = await whisper.transcribe(audioPath: c.audio, translate: c.translate) ?? ""
            let elapsed = ms(since: t)
            let retries = whisper.languageRetryCount - retriesBefore

            let got = normalize(text)
            var failed: [String] = []
            if !c.anyText {
                if text.isEmpty { failed.append("empty result") }
                if let ending = c.expectEndsWith, !got.hasSuffix(normalize(ending)) {
                    failed.append("should end with \"\(ending)\"")
                }
                for part in c.expectContains where !got.contains(normalize(part)) {
                    failed.append("should contain \"\(part)\"")
                }
                for part in c.mustNotContain where got.contains(normalize(part)) {
                    failed.append("must not contain \"\(part)\"")
                }
                for ending in c.mustNotEndWith where got.hasSuffix(normalize(ending)) {
                    failed.append("must not end with \"\(ending)\"")
                }
            }
            if retries != (c.expectRetry ? 1 : 0) {
                failed.append("language retries: \(retries), want \(c.expectRetry ? 1 : 0)")
            }

            var detail = ["spoken": c.spoken, "text": text, "mode": c.translate ? "translate" : "transcribe"]
            if let languages = c.languages { detail["languages"] = languages.joined(separator: ",") }
            if retries > 0 { detail["retries"] = "\(retries)" }
            if !failed.isEmpty { detail["failed"] = failed.joined(separator: "; ") }
            r.step(c.id, ok: failed.isEmpty, ms: elapsed, detail)

            if c.live { await runLive(c, final: text, whisper: whisper, &r) }
        }
    }

    /// The clip played back in real time — the loop sees only as much of it
    /// as has "been recorded" — through the real preview path, into a
    /// document that stands in for the app being typed into. Then the final
    /// text, as on key release.
    private static func runLive(_ c: VoiceCase, final: String, whisper: WhisperService, _ r: inout Report) async {
        guard let all = try? AudioProcessor.loadAudioAsFloatArray(fromPath: c.audio), !all.isEmpty else {
            r.step("\(c.id): live — audio loads", ok: false)
            return
        }
        let seconds = Double(all.count) / 16000
        let document = LiveDocument()
        let typer = LiveTyper(sink: document)
        /// (ms since the recording began, what the document said then)
        var timeline: [(Int, String)] = []

        let live = LiveDictation()
        let began = Date()
        live.start(whisper: whisper, translate: false, threshold: Settings.shared.silenceThreshold,
                   audio: {
                       let heard = min(all.count, Int(Date().timeIntervalSince(began) * 16000))
                       return AudioRecorder.Snapshot(samples: Array(all[..<heard]), sampleRate: 16000, peak: 1)
                   },
                   onText: { text in
                       typer.update(to: text)
                       timeline.append((ms(since: began), document.text))
                   })
        try? await Task.sleep(nanoseconds: UInt64((seconds + 0.2) * 1_000_000_000))

        // Key released: the loop must let go of the model, and stay quiet.
        let stopping = Date()
        await live.stop()
        let stopMs = ms(since: stopping)
        let (atStop, updatesAtStop) = await MainActor.run { (document.text, typer.updates) }
        try? await Task.sleep(nanoseconds: 400_000_000)
        let quiet = await MainActor.run { typer.updates == updatesAtStop }

        await MainActor.run { typer.finish(with: final) }
        let (text, mismatches, edits) = await MainActor.run { (document.text, document.mismatches, document.edits) }
        let deleted = edits.reduce(0) { $0 + $1.deleted.count }
        let inserted = edits.reduce(0) { $0 + $1.inserted.count }
        let lastFix = edits.last.map { "-\($0.deleted.count) +\($0.inserted.count)" } ?? "none"

        var detail: [String: String] = [
            "audioSeconds": String(format: "%.1f", seconds),
            "previews": "\(live.passes)",
            "firstTextMs": timeline.first.map { "\($0.0)" } ?? "never",
            "stopMs": "\(stopMs)",
            "charsDeleted": "\(deleted)", "charsInserted": "\(inserted)",
            "finalCorrection": lastFix,
            "atRelease": atStop,
        ]
        for (index, entry) in timeline.enumerated() { detail[String(format: "t%02d @%dms", index, entry.0)] = entry.1 }

        r.step("\(c.id): live — text appears while still speaking", ok: !timeline.isEmpty && live.passes >= 2, detail)
        r.step("\(c.id): live — every correction deleted exactly what had been written", ok: mismatches == 0,
               ["edits": "\(edits.count)"])
        r.step("\(c.id): live — nothing is written after the key is released", ok: quiet, ms: stopMs)
        r.step("\(c.id): live — the document ends as the final text", ok: text == final && !final.isEmpty,
               text == final ? [:] : ["document": text, "final": final])
    }
}
