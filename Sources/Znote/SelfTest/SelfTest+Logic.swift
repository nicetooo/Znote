import Foundation

/// Scenario `logic` — everything that is pure decision-making: no model, no
/// network, no files beyond the app bundle.
extension SelfTest {
    static func runLogic(_ r: inout Report) {
        let s = Settings.shared
        let store = Settings.store

        // ── Isolation: the store must start empty, i.e. not be the user's. ──
        r.expect("isolation: store starts empty", store.persistentDomain(forName: defaultsDomain)?.count ?? 0, 0)
        r.expect("isolation: no saved hotkey leaks in", store.string(forKey: "hotkey.screenshot.side"), nil)

        // ── Defaults when nothing is saved ──
        r.expect("default: languages", s.selectedLanguages, [])
        r.expect("default: model", s.whisperModel, "large-v3")
        r.expect("default: silence threshold", s.silenceThreshold, 0.05)
        r.expect("default: min duration", s.minRecordingDuration, 0.5)

        // ── Language selection → Whisper language argument + Chinese conversion ──
        // (selected, forced language, convert to simplified, convert to traditional)
        let languageCases: [([String], String?, Bool, Bool)] = [
            ([], nil, false, false),
            (["en"], "en", false, false),
            (["zh-Hans"], "zh", true, false),
            (["zh-Hant"], "zh", false, true),
            (["zh-Hans", "zh-Hant"], "zh", false, false),   // both scripts → one Whisper language, no conversion
            (["zh-Hans", "en"], nil, true, false),          // several → auto-detect
            (["zh-Hant", "en", "ja"], nil, false, true),
        ]
        for (selected, forced, simplified, traditional) in languageCases {
            s.selectedLanguages = selected
            let label = selected.isEmpty ? "(none)" : selected.joined(separator: "+")
            r.expect("languages \(label): forced", s.whisperLanguageArg, forced)
            r.expect("languages \(label): →simplified", s.chineseSimplified, simplified)
            r.expect("languages \(label): →traditional", s.chineseTraditional, traditional)
        }
        s.selectedLanguages = []

        // ── Model name migration ──
        for (stored, effective) in [
            ("mlx-community/whisper-large-v3-turbo", "large-v3"),  // pre-WhisperKit format
            ("medium", "large-v3"),                                // removed from the list
            ("distil-large-v3", "large-v3"),
            ("small", "small"),
            ("large-v3-v20240930", "large-v3-v20240930"),
            ("large-v3_947MB", "large-v3_947MB"),
            ("large-v3-v20240930_626MB", "large-v3-v20240930_626MB"),
        ] {
            s.whisperModel = stored
            r.expect("model '\(stored)' resolves", s.whisperModel, effective)
        }
        store.removeObject(forKey: "whisperModel")

        r.expect("translate task: large-v3", WhisperService.supportsTranslate("large-v3"), true)
        r.expect("translate task: small", WhisperService.supportsTranslate("small"), true)
        r.expect("translate task: turbo", WhisperService.supportsTranslate("large-v3-v20240930"), false)
        r.expect("translate task: large-v3 compact", WhisperService.supportsTranslate("large-v3_947MB"), true)
        r.expect("translate task: turbo compact", WhisperService.supportsTranslate("large-v3-v20240930_626MB"), false)

        // ── Silence gate ──
        s.silenceThreshold = 0.2
        r.expect("threshold: saved value used", s.silenceThreshold, 0.2)
        s.silenceThreshold = 0
        r.expect("threshold: 0 falls back to default", s.silenceThreshold, 0.05)
        // (duration, peak) against threshold 0.05 / minDuration 0.5
        for (duration, peak, want) in [(1.0, Float(0.30), true), (0.5, Float(0.05), true),
                                       (0.49, Float(0.30), false), (1.0, Float(0.049), false)] {
            r.expect("gate: \(duration)s peak \(peak)",
                     AudioRecorder.isMeaningful(duration: duration, peak: peak, threshold: 0.05, minDuration: 0.5), want)
        }

        runHotkeySettings(&r)
        runHallucinationFilter(&r)
        runTranslationDirection(&r)
        runLocalization(&r)
    }

    // MARK: - Hotkey bindings

    private static func runHotkeySettings(_ r: inout Report) {
        let s = Settings.shared
        let store = Settings.store
        func describe(_ b: HotkeyBinding) -> String { "\(b.side.rawValue) \(b.modifier.rawValue) \(b.gesture.rawValue)" }
        func conflicts() -> [String] {
            s.hotkeyConflicts().map { "\($0.0.rawValue)↔\($0.1.rawValue)" }
        }

        for (action, want) in [
            (HotkeyAction.voiceInput, "right cmd hold"), (.toggleHistory, "right cmd tap"),
            (.voiceTranslate, "right option hold"), (.translate, "right option tap"),
            (.screenshot, "right option doubleTap"),
        ] {
            r.expect("hotkey default: \(action.rawValue)", describe(s.hotkeyBinding(for: action)), want)
        }
        r.expect("hotkey: defaults don't conflict", conflicts(), [])

        // Round trip.
        s.setHotkeyBinding(HotkeyBinding(side: .left, modifier: .control, gesture: .tap), for: .screenshot)
        r.expect("hotkey: saved binding reads back", describe(s.hotkeyBinding(for: .screenshot)), "left control tap")

        // Same key + same gesture on two actions is a conflict; same key with
        // different gestures is not.
        s.setHotkeyBinding(HotkeyBinding(side: .right, modifier: .cmd, gesture: .tap), for: .translate)
        r.expect("hotkey: duplicate binding detected", conflicts(), ["toggleHistory↔translate"])
        s.setHotkeyBinding(HotkeyBinding(side: .right, modifier: .cmd, gesture: .doubleTap), for: .translate)
        r.expect("hotkey: same key, other gesture is fine", conflicts(), [])

        // Push-to-talk actions can only be "hold", whatever is stored.
        store.set("tap", forKey: "hotkey.voiceInput.gesture")
        r.expect("hotkey: voice input stays hold", s.hotkeyBinding(for: .voiceInput).gesture, .hold)
        store.set("hold", forKey: "hotkey.toggleHistory.gesture")
        r.expect("hotkey: tap action can't become hold", s.hotkeyBinding(for: .toggleHistory).gesture, .tap)
        store.set("sideways", forKey: "hotkey.voiceInput.side")
        r.expect("hotkey: garbage side falls back", s.hotkeyBinding(for: .voiceInput).side, .right)

        s.resetHotkeys()
        r.expect("hotkey: reset restores defaults",
                 HotkeyAction.allCases.map { s.hotkeyBinding(for: $0) }, HotkeyAction.allCases.map(\.defaultBinding))
        r.expect("hotkey: no conflicts after reset", conflicts(), [])
    }

    // MARK: - Hallucination filter

    private static func runHallucinationFilter(_ r: inout Report) {
        let cases: [(String, String)] = [
            // Kept: the phrase is part of the sentence.
            ("I will send the file to you.", "I will send the file to you."),
            ("Let me play some music", "Let me play some music"),
            ("I just wanted to say thank you.", "I just wanted to say thank you."),
            ("Please read it to the end.", "Please read it to the end."),
            ("I'd like to say, thank you.", "I'd like to say, thank you."),
            ("We said goodbye", "We said goodbye"),
            ("Is it you?", "Is it you?"),
            ("Well...", "Well..."),
            ("好的...", "好的..."),
            ("Envíalo a you", "Envíalo a you"),
            ("今天开会，会后发给你", "今天开会，会后发给你"),
            ("今天开会。", "今天开会。"),
            ("He said \"hi\" thank you", "He said \"hi\" thank you"),
            // Removed: the phrase stands apart from what precedes it.
            ("今天我们开会。Thank you.", "今天我们开会。"),
            ("今天我们开会。 Thank you.", "今天我们开会。"),
            ("今天我们开会 Thank you.", "今天我们开会"),
            ("今天我们开会，thank you", "今天我们开会"),
            ("今天我们开会 you", "今天我们开会"),
            ("今天我们开会Thank you", "今天我们开会"),
            ("こんにちは Thank you.", "こんにちは"),
            ("今天开会。Thank you. Bye.", "今天开会。"),
            ("That's all for today. Thanks for watching.", "That's all for today."),
            ("Thank you.", ""),
            ("  Thanks for watching!  ", ""),
            ("Thank you. Bye.", ""),
            (", thank you", ""),
            ("", ""),
        ]
        var wrong: [String] = []
        for (input, want) in cases {
            let got = HallucinationFilter.removeTrailing(from: input)
            if got != want { wrong.append("\"\(input)\" → \"\(got)\" (want \"\(want)\")") }
        }
        r.step("hallucination filter: \(cases.count) cases", ok: wrong.isEmpty,
               wrong.isEmpty ? [:] : ["wrong": wrong.joined(separator: " | ")])
    }

    // MARK: - Translation direction

    /// Which way each text in the `translate` table would go — the offline
    /// half of that scenario (no request is made here).
    private static func runTranslationDirection(_ r: inout Report) {
        var wrong: [String] = []
        for c in translateCases {
            let direction = TranslationService.plan(for: c.text).target == "en" ? "en" : "zh"
            if direction != c.want { wrong.append("\"\(c.text)\" went →\(direction)") }
        }
        r.step("translation direction: \(translateCases.count) texts", ok: wrong.isEmpty,
               wrong.isEmpty ? [:] : ["wrong": wrong.joined(separator: " | ")])

        // Naming the source is what stops Google returning mixed text untouched.
        r.expect("translation: English with Chinese words names its source",
                 TranslationService.plan(for: "Send it to 张三 tomorrow"),
                 TranslationService.Plan(source: "en", target: "zh-CN", sourceParam: "en"))
        r.expect("translation: Chinese with English terms → English",
                 TranslationService.plan(for: "merge 一下 PR"),
                 TranslationService.Plan(source: "zh", target: "en", sourceParam: "auto"))
        r.expect("translation: plain English stays on auto-detect",
                 TranslationService.plan(for: "The meeting starts at three this afternoon.").sourceParam, "auto")
    }

    // MARK: - Localization

    private static func runLocalization(_ r: inout Report) {
        func table(_ language: String) -> [String: String] {
            guard let url = Bundle.main.url(forResource: "Localizable", withExtension: "strings",
                                            subdirectory: nil, localization: language),
                  let dict = NSDictionary(contentsOf: url) as? [String: String] else { return [:] }
            return dict
        }
        let en = table("en"), zh = table("zh-Hans")
        r.step("i18n: both tables are in the bundle", ok: !en.isEmpty && !zh.isEmpty,
               ["en": "\(en.count) keys", "zh-Hans": "\(zh.count) keys"])
        guard !en.isEmpty, !zh.isEmpty else { return }

        let onlyEn = Set(en.keys).subtracting(zh.keys).sorted()
        let onlyZh = Set(zh.keys).subtracting(en.keys).sorted()
        r.step("i18n: same keys in both languages", ok: onlyEn.isEmpty && onlyZh.isEmpty,
               ["onlyEn": onlyEn.joined(separator: ","), "onlyZhHans": onlyZh.joined(separator: ",")])

        // A translation whose %-placeholders differ from the English ones
        // crashes or garbles String(format:).
        let specifier = try? NSRegularExpression(pattern: #"%(?:\d+\$)?[-+0 #]*\d*(?:\.\d+)?(?:l{0,2})[@dDuUxXfFeEgGcCsS]"#)
        func placeholders(_ raw: String) -> [String] {
            let s = raw.replacingOccurrences(of: "%%", with: "") as NSString
            return (specifier?.matches(in: s as String, range: NSRange(location: 0, length: s.length)) ?? [])
                .map { s.substring(with: $0.range) }
                .sorted()
        }
        let mismatched = en.keys.sorted().filter { placeholders(en[$0] ?? "") != placeholders(zh[$0] ?? "") }
        r.step("i18n: same format placeholders", ok: mismatched.isEmpty, ["mismatched": mismatched.joined(separator: ",")])

        // A lookup that returns its own key means the running bundle didn't
        // resolve the table at all.
        r.step("i18n: runtime lookup resolves", ok: L("menu.quit") != "menu.quit", ["menu.quit": L("menu.quit")])
    }
}
