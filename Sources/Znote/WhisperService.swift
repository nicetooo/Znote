import AVFoundation
import CoreML
import Foundation
import NaturalLanguage
import WhisperKit

/// Transcribes audio using WhisperKit (CoreML-native, no Python/ffmpeg needed).
class WhisperService {
    // Model state is touched from the main thread (overlay decisions) and
    // from background tasks (loading, transcribing), so it sits behind a lock.
    private let stateLock = NSLock()
    private var _whisperKit: WhisperKit?
    private var _loadedModel = ""
    private var _isLoading = false

    private func locked<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }
    private var whisperKit: WhisperKit? {
        get { locked { _whisperKit } }
        set { locked { _whisperKit = newValue } }
    }
    private var loadedModel: String {
        get { locked { _loadedModel } }
        set { locked { _loadedModel = newValue } }
    }
    var isLoading: Bool { locked { _isLoading } }

    /// How many times a transcription was re-run with a forced language
    /// because the auto-detected one wasn't among the user's languages.
    /// Each retry doubles that transcription's time; the self-test watches it.
    private(set) var languageRetryCount = 0

    /// Whether a model is loaded and ready for transcription
    var isModelReady: Bool { whisperKit != nil && !loadedModel.isEmpty }

    /// Fired on the main actor whenever a model finishes loading successfully.
    /// AppDelegate uses this to swap the recording overlay from "Loading model..."
    /// to the waveform if the user is already holding the record hotkey.
    var onModelReady: (() -> Void)?

    /// Transcribe audio file. Returns the text or nil on failure.
    /// Call from a Task {} context (async).
    ///
    /// - Parameters:
    ///   - audioPath: PCM file produced by AudioRecorder.
    ///   - translate: When true, switch Whisper into `task=translate` mode.
    ///     The decoder outputs ENGLISH text regardless of the spoken language —
    ///     this is Whisper's native any-language → English translation. Source
    ///     language verification + Chinese conversion are skipped in this mode
    ///     because the output is always English by definition.
    func transcribe(audioPath: String, translate: Bool = false) async -> String? {
        guard FileManager.default.fileExists(atPath: audioPath) else {
            log("Whisper: audio file not found: \(audioPath)")
            return nil
        }

        // Ensure model is loaded
        let model = Settings.shared.whisperModel
        log("Whisper: transcribe called, model=\(model), loaded=\(loadedModel), kit=\(whisperKit == nil ? "nil" : "ok"), isLoading=\(isLoading), translate=\(translate)")
        if whisperKit == nil || loadedModel != model {
            guard await loadModel(model) else { return nil }
        }

        guard let kit = whisperKit else {
            log("Whisper: not initialized")
            return nil
        }

        let forcedLang = Settings.shared.whisperLanguageArg
        let options = WhisperService.decodingOptions(translate: translate, forcedLanguage: forcedLang)

        let modeLabel = translate ? "translate→en" : "transcribe"
        log("Whisper: \(modeLabel) (model: \(model), lang: \(forcedLang ?? "auto"))...")
        let startTime = Date()

        do {
            let results: [TranscriptionResult] = try await kit.transcribe(audioPath: audioPath, decodeOptions: options)

            guard let result = results.first else {
                log("Whisper: no result")
                return nil
            }

            let detectedLang = result.language
            let elapsed = String(format: "%.1f", Date().timeIntervalSince(startTime))

            let spoken = WhisperService.spokenText(of: result)
            var rawText = spoken.text
            log("Whisper: done in \(elapsed)s, detected=\(detectedLang), segments=\(result.segments.count)→\(spoken.kept), text=\(rawText.prefix(100))")

            // Language verification + retry only makes sense in transcribe mode —
            // in translate mode the OUTPUT language is always English by design,
            // so checking against the user's `selectedLanguages` (which describes
            // input languages) would always fail and trigger pointless retries.
            if !translate, forcedLang == nil, !Settings.shared.selectedLanguages.isEmpty {
                let cleaned = cleanupTranscription(rawText)
                if !WhisperService.isLanguageExpected(cleaned, selected: Settings.shared.selectedLanguages) {
                    if let retryLang = bestRetryLanguage() {
                        log("Whisper: language mismatch, retrying with forced '\(retryLang)'")
                        languageRetryCount += 1
                        var retryOptions = options
                        retryOptions.language = retryLang
                        retryOptions.detectLanguage = false
                        if let retryResults: [TranscriptionResult] = try? await kit.transcribe(audioPath: audioPath, decodeOptions: retryOptions),
                           let retryResult = retryResults.first {
                            rawText = retryResult.text
                        }
                    }
                }
            }

            var finalText = cleanupTranscription(rawText)
            finalText = HallucinationFilter.removeTrailing(from: finalText)
            if finalText.isEmpty {
                log("Whisper: result empty after hallucination filtering, discarding")
                return nil
            }
            // Skip Hans/Hant conversion in translate mode (output is English).
            if !translate {
                finalText = convertChineseIfNeeded(finalText)
            }
            log("Whisper: result = \"\(finalText)\"")
            return finalText

        } catch {
            log("Whisper: transcription failed: \(error)")
            return nil
        }
    }

    // MARK: - Shared between the final pass and the live preview

    /// How every pass is decoded.
    static func decodingOptions(translate: Bool, forcedLanguage: String?) -> DecodingOptions {
        var options = DecodingOptions()
        // In translate mode we let Whisper auto-detect the source language —
        // forcing the source here also works, but auto is more robust when the
        // user holds the translate hotkey and switches between Chinese / French
        // / etc. without changing Settings.
        if translate {
            options.task = .translate
            options.language = nil
            options.detectLanguage = true
        } else {
            options.language = forcedLanguage
            options.detectLanguage = (forcedLanguage == nil)
        }
        options.verbose = false
        options.suppressBlank = true
        // Thresholds tuned to suppress hallucinations on silence
        options.noSpeechThreshold = 0.6
        options.logProbThreshold = -1.0
        options.compressionRatioThreshold = 2.4
        // Speed flags — skip timestamp tokens (decode fewer tokens, also solves
        // the <|0.00|> token leak we saw on multi-segment outputs) and disable
        // temperature fallback retries. Our hallucination filter is the safety
        // net for the edge cases fallback would normally catch.
        options.withoutTimestamps = true
        options.wordTimestamps = false
        options.temperatureFallbackCount = 0
        return options
    }

    /// A result's text without the segments Whisper itself thinks are
    /// silence (hallucinated on it), and how many segments were kept.
    static func spokenText(of result: TranscriptionResult, quiet: Bool = false) -> (text: String, kept: Int) {
        let segments = result.segments.filter { segment in
            let dominated = segment.noSpeechProb > 0.6 && segment.avgLogprob < -0.7
            if dominated, !quiet {
                log("Whisper: dropping segment (noSpeech=\(String(format: "%.2f", segment.noSpeechProb)), avgLogP=\(String(format: "%.2f", segment.avgLogprob))): \"\(segment.text.prefix(60))\"")
            }
            return !dominated
        }
        var text = segments.map { $0.text }.joined(separator: " ")
        if text.isEmpty && !result.text.isEmpty {
            // Fallback: if all segments were filtered, use original (rare edge case)
            text = result.text
        }
        return (text, segments.count)
    }

    // MARK: - Live preview

    /// What a recording still in progress says so far. `samples` are mono at
    /// 16 kHz (see `resample`). The same decoding and clean-up as the final
    /// pass, minus the second pass a language mismatch would cost: a preview
    /// in an unexpected language is dropped instead, and the next one tried.
    ///
    /// Returns nil when there is nothing worth showing, when the model isn't
    /// loaded (a preview never loads one), or when the calling task was
    /// cancelled — which is how the final pass gets the model to itself.
    func transcribePreview(samples: [Float], translate: Bool = false) async -> String? {
        guard let kit = whisperKit, loadedModel == Settings.shared.whisperModel, !samples.isEmpty else { return nil }
        let forcedLang = Settings.shared.whisperLanguageArg
        let options = WhisperService.decodingOptions(translate: translate, forcedLanguage: forcedLang)
        do {
            let results: [TranscriptionResult] = try await kit.transcribe(audioArray: samples, decodeOptions: options)
            guard !Task.isCancelled, let result = results.first else { return nil }
            var text = cleanupTranscription(WhisperService.spokenText(of: result, quiet: true).text)
            if !translate, forcedLang == nil, !Settings.shared.selectedLanguages.isEmpty,
               !WhisperService.isLanguageExpected(text, selected: Settings.shared.selectedLanguages) {
                return nil
            }
            text = HallucinationFilter.removeTrailing(from: text)
            if !translate { text = convertChineseIfNeeded(text, quiet: true) }
            return text.isEmpty ? nil : text
        } catch {
            if !(error is CancellationError) { log("Whisper: preview failed: \(error)") }
            return nil
        }
    }

    /// Mono samples at any rate → the 16 kHz Whisper takes.
    static func resample(_ samples: [Float], from sampleRate: Double) -> [Float] {
        guard sampleRate != 16000, sampleRate > 0, !samples.isEmpty else { return samples }
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return [] }
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        guard let resampled = AudioProcessor.resampleAudio(fromBuffer: buffer, toSampleRate: 16000, channelCount: 1) else { return [] }
        return AudioProcessor.convertBufferToArray(buffer: resampled)
    }

    // MARK: - Model Loading

    /// Load a WhisperKit model. Returns true on success.
    func loadModel(_ variant: String) async -> Bool {
        // Check and claim in one step, so two callers can't both start a load.
        let alreadyLoading: Bool = locked {
            if _isLoading { return true }
            _isLoading = true
            return false
        }
        guard !alreadyLoading else {
            log("Whisper: already loading a model, please wait")
            return false
        }
        defer { locked { _isLoading = false } }

        log("Whisper: loading model '\(variant)'...")
        let startTime = Date()

        do {
            // ANE (Neural Engine) is 3-5× faster than CPU+GPU on Apple Silicon,
            // but CoreML's ANE compilation is known to hang on the large-v* variants.
            // Use ANE for smaller models, CPU+GPU for large.
            let compute = WhisperService.computeOptions(for: variant)

            let config = WhisperKitConfig(
                model: variant,
                downloadBase: Settings.modelStorageDir,
                computeOptions: compute,
                verbose: false,
                logLevel: .error,
                prewarm: true,   // warm CoreML compute pipelines at load time
                load: true,
                download: true
            )

            log("Whisper: calling WhisperKit init (variant=\(variant), base=\(Settings.modelStorageDir.path))...")
            whisperKit = try await WhisperKit(config)
            loadedModel = variant

            let elapsed = String(format: "%.1f", Date().timeIntervalSince(startTime))
            log("Whisper: model '\(variant)' loaded in \(elapsed)s ✓")
            let readyCallback = onModelReady
            await MainActor.run { readyCallback?() }
            return true
        } catch {
            log("Whisper: FAILED to load model '\(variant)': \(error)")
            whisperKit = nil
            loadedModel = ""
            return false
        }
    }

    /// Unload the current model to free memory
    func unloadModel() {
        whisperKit = nil
        loadedModel = ""
        log("Whisper: model unloaded")
    }

    /// Whether a given Whisper variant supports the `task=translate` decoding mode.
    /// OpenAI's Sep 2024 Turbo release (`large-v3-v20240930`) dropped translation
    /// training to win ~8× speed. All other "standard" Whisper variants do support
    /// translate — large-v3, small, medium, etc.
    static func supportsTranslate(_ variant: String) -> Bool {
        let lower = variant.lowercased()
        // Turbo flavours — OpenAI's Sep-2024 release and any "*turbo*" naming.
        if lower.contains("v20240930") || lower.contains("turbo") {
            return false
        }
        return true
    }

    /// Pick compute units per variant. large-v* are forced to CPU+GPU because
    /// CoreML's ANE path is known to hang on their weights; everything else
    /// gets ANE (cpuAndNeuralEngine) which is 3-5× faster on Apple Silicon.
    private static func computeOptions(for variant: String) -> ModelComputeOptions {
        let lower = variant.lowercased()
        let isLarge = lower.hasPrefix("large") || lower.contains("distil-large")
        let unit: MLComputeUnits = isLarge ? .cpuAndGPU : .cpuAndNeuralEngine
        log("Whisper: compute for '\(variant)' = \(isLarge ? "CPU+GPU" : "ANE")")
        return ModelComputeOptions(
            melCompute: .cpuAndGPU,  // mel is small; GPU is fine
            audioEncoderCompute: unit,
            textDecoderCompute: unit,
            prefillCompute: unit
        )
    }

    // MARK: - Language Verification

    /// Whether `text` is in one of the languages the user said they speak.
    /// A "no" makes the caller transcribe again with the language forced.
    static func isLanguageExpected(_ text: String, selected: [String]) -> Bool {
        let selectedBases = Set(selected.map { $0.components(separatedBy: "-").first ?? $0 })

        // Chinese characters, and Chinese is one of the user's languages:
        // expected, whatever English is mixed in. NLLanguageRecognizer reads
        // "这个 API 的 response 格式不对" as Indonesian, which used to trigger a
        // pointless second pass on every mixed sentence. (Kana means Japanese,
        // which the recognizer handles.)
        if selectedBases.contains("zh") {
            let scalars = text.unicodeScalars
            let hasHan = scalars.contains { (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value) }
            let hasKana = scalars.contains { (0x3040...0x30FF).contains($0.value) }
            if hasHan && !hasKana { return true }
        }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let detected = recognizer.dominantLanguage else { return true }

        let detectedBase = detected.rawValue.components(separatedBy: "-").first ?? detected.rawValue
        let expected = selectedBases.contains(detectedBase)
        if !expected {
            log("Whisper: NLLanguageRecognizer detected '\(detected.rawValue)' — not in selected \(selected)")
        }
        return expected
    }

    private func bestRetryLanguage() -> String? {
        guard let first = Settings.shared.selectedLanguages.first else { return nil }
        return Settings.whisperCode(for: first)
    }

    // MARK: - Line Cleanup

    private func cleanupTranscription(_ text: String) -> String {
        // Strip WhisperKit special tokens: <|startoftranscript|>, <|zh|>,
        // <|transcribe|>, <|0.00|>, <|endoftext|>, etc. These appear on
        // multi-segment outputs because segment.text includes raw timestamps.
        let stripped = text.replacingOccurrences(
            of: #"<\|[^|]*\|>"#,
            with: "",
            options: .regularExpression
        )
        return stripped
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // MARK: - Chinese Conversion

    private func convertChineseIfNeeded(_ text: String, quiet: Bool = false) -> String {
        if Settings.shared.chineseSimplified {
            let mutable = NSMutableString(string: text)
            CFStringTransform(mutable, nil, "Hant-Hans" as CFString, false)
            let converted = mutable as String
            if converted != text, !quiet { log("Whisper: converted traditional → simplified") }
            return converted
        } else if Settings.shared.chineseTraditional {
            let mutable = NSMutableString(string: text)
            CFStringTransform(mutable, nil, "Hans-Hant" as CFString, false)
            let converted = mutable as String
            if converted != text, !quiet { log("Whisper: converted simplified → traditional") }
            return converted
        }
        return text
    }
}
