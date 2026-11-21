import Foundation

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
        }
    }
}
