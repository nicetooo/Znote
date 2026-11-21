import Foundation

/// Scenario `bench` — measures a model rather than judging the app: character
/// error rate and time per clip over the reference sentences `seed.py`
/// synthesized (Chinese, English and mixed; clean and with added noise).
/// A clip only "fails" if nothing came back. Compare models with
/// `selftest/bench.sh`.
extension SelfTest {
    private struct BenchManifest: Decodable {
        let model: String
        let languages: [String]
        /// Let WhisperKit download the model if it isn't cached (the normal
        /// scenarios never do).
        let allowDownload: Bool
        let clips: [Clip]
    }

    private struct Clip: Decodable {
        let id: String
        let audio: String
        let reference: String
        let group: String       // zh | en | mixed
        let condition: String   // clean | noisy
    }

    static func runBench(_ request: Request, _ r: inout Report) async {
        let manifest: BenchManifest
        do {
            manifest = try JSONDecoder().decode(
                BenchManifest.self, from: Data(contentsOf: request.dir.appendingPathComponent("manifest.json")))
        } catch {
            r.errors.append("manifest: \(error)")
            return
        }

        Settings.shared.whisperModel = manifest.model
        Settings.shared.selectedLanguages = manifest.languages
        let model = Settings.shared.whisperModel
        r.env["model"] = model
        r.env["languages"] = manifest.languages.joined(separator: ",")
        guard model == manifest.model else {
            r.errors.append("model '\(manifest.model)' is not in Settings.popularModels (resolved to '\(model)')")
            return
        }

        let cached = Settings.cachedModelNames().contains(model)
        r.step("model-cached", ok: cached || manifest.allowDownload, ["model": model, "cached": "\(cached)"])
        guard cached || manifest.allowDownload else { return }

        let whisper = WhisperService()
        var t = Date()
        let loaded = await whisper.loadModel(model)
        let loadMs = ms(since: t)
        r.step("model-load", ok: loaded, ms: loadMs, ["model": model, "downloaded": "\(!cached)"])
        guard loaded else { return }
        r.env["loadMs"] = "\(loadMs)"
        r.env["modelSize"] = Settings.cachedModelSize(model)

        // One throwaway pass so the first measured clip doesn't pay for warm-up.
        if let first = manifest.clips.first {
            _ = await whisper.transcribe(audioPath: first.audio)
        }

        for clip in manifest.clips {
            let retriesBefore = whisper.languageRetryCount
            t = Date()
            let text = await whisper.transcribe(audioPath: clip.audio) ?? ""
            let elapsed = ms(since: t)
            let cer = characterErrorRate(text, reference: clip.reference)
            r.step(clip.id, ok: !text.isEmpty, ms: elapsed, [
                "reference": clip.reference, "text": text,
                "group": clip.group, "condition": clip.condition,
                "cer": String(format: "%.4f", cer),
                // A retry means the language check re-ran the whole clip.
                "retries": "\(whisper.languageRetryCount - retriesBefore)",
            ])
        }
    }

    /// Edit distance between the normalized strings, over the reference length.
    /// Normalizing drops case, spacing and punctuation, so only the words count.
    static func characterErrorRate(_ text: String, reference: String) -> Double {
        let a = Array(normalize(reference)), b = Array(normalize(text))
        guard !a.isEmpty else { return b.isEmpty ? 0 : 1 }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            if !b.isEmpty {
                for j in 1...b.count {
                    current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
                }
            }
            previous = current
        }
        return Double(previous[b.count]) / Double(a.count)
    }
}
