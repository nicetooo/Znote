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

        // ── Language check that decides whether to transcribe a second time ──
        // (text, selected languages, should it count as expected?)
        for (text, selected, want) in [
            ("这个 API 的 response 格式不对", ["zh-Hans", "en"], true),     // mixed: used to be read as Indonesian
            ("merge 一下 PR", ["zh-Hans", "en"], true),
            ("我们用 React 和 TypeScript 写前端", ["zh-Hans"], true),
            ("I will send the file to you.", ["zh-Hans", "en"], true),
            ("I will send the file to you.", ["zh-Hans", "ja"], false),    // English when it isn't selected
            ("今天下午开会", ["en"], false),
            ("今日は会議があります", ["zh-Hans", "ja"], true),              // kana → Japanese, selected
            ("今日は会議があります", ["zh-Hans", "en"], false),             // kanji alone don't make it Chinese
        ] {
            r.expect("language check: \"\(text)\" with \(selected.joined(separator: "+"))",
                     WhisperService.isLanguageExpected(text, selected: selected), want)
        }

        runHotkeySettings(&r)
        runLiveText(&r)
        runHallucinationFilter(&r)
        runTranslationDirection(&r)
        runLocalization(&r)
    }

    // MARK: - Live dictation

    /// Stands in for wherever live text is written: carries the edits out on
    /// a string, and notes any that asked to delete something that isn't there.
    final class LiveDocument: LiveTextSink {
        var text = ""
        var edits: [LiveEdit] = []
        var mismatches = 0

        func apply(_ edit: LiveEdit) {
            edits.append(edit)
            if text.hasSuffix(edit.deleted) {
                text.removeLast(edit.deleted.count)
            } else {
                mismatches += 1
            }
            text += edit.inserted
        }
    }

    private static func runLiveText(_ r: inout Report) {
        r.expect("default: live dictation on", Settings.shared.liveDictation, true)

        // (written, target, deleted, inserted)
        let edits: [(String, String, String, String)] = [
            ("", "hello", "", "hello"),
            ("hello", "hello", "", ""),
            ("hello wor", "hello world today", "", "ld today"),
            ("I sent the fire", "I sent the file to you", "re", "le to you"),
            ("今天下午我们开回", "今天下午我们开会，会后", "回", "会，会后"),
            ("hello world", "", "hello world", ""),
            ("发布 release note", "发布 release notes 到群里", "", "s 到群里"),
            ("ok 👍🏽 done", "ok 👍 done", "👍🏽 done", "👍 done"),     // one backspace per visible character
            ("Thank you", "今天", "Thank you", "今天"),
        ]
        for (written, target, deleted, inserted) in edits {
            r.expect("live edit: \"\(written)\" → \"\(target)\"",
                     LiveText.edit(from: written, to: target), LiveEdit(deleted: deleted, inserted: inserted))
        }

        for (hypothesis, want) in [
            ("I will send the file.", "I will send the file"),
            ("我们今天就先讨论到这里。", "我们今天就先讨论到这里"),
            ("Wait... ", "Wait"),
            ("version 2.0", "version 2.0"),
            ("first, second,", "first, second"),
            ("。", ""),
        ] {
            r.expect("live preview \"\(hypothesis)\" is written without its closing punctuation",
                     LiveText.interim(hypothesis), want)
        }

        // A new preview keeps what is written where only punctuation, spacing
        // or capitals changed. (written, preview, what is written next)
        let settled: [(String, String, String)] = [
            ("", "hello", "hello"),
            ("今天下午开会", "今天下午开会，会后", "今天下午开会，会后"),
            ("发布计划,会后我把", "发布计划会后我把release", "发布计划,会后我把release"),            // the comma came and went
            ("会后我把release notes", "会后我把Release Notes发到群里", "会后我把release notes发到群里"),  // capitals
            ("release notes 发到群里", "release notes发到群里大家", "release notes 发到群里大家"),      // spacing
            ("I think the second sentence", "I think the second section needs", "I think the second section needs"),  // a word did change
            ("abc def", "abc, xyz", "abc, xyz"),                                                        // …and the new punctuation comes with it
            ("I will send the file to you", "I will send the file", "I will send the file"),            // the preview says less
            ("Thank you", "今天", "今天"),
        ]
        for (written, preview, want) in settled {
            r.expect("live preview \"\(preview)\" over \"\(written)\"", LiveText.settled(written: written, preview: preview), want)
        }
        let commaDocument = LiveDocument()
        let softTyper = LiveTyper(sink: commaDocument)
        softTyper.update(to: "发布计划,会后我把")
        softTyper.update(to: "发布计划会后我把Release Notes")
        softTyper.update(to: "发布计划,会后我把release notes发到群里")
        r.step("live typer: a comma or capital that comes and goes costs no backspaces",
               ok: commaDocument.edits.allSatisfy { $0.deleted.isEmpty } && commaDocument.text == "发布计划,会后我把Release Notes发到群里",
               ["text": commaDocument.text])
        softTyper.finish(with: "发布计划，会后我把 release notes 发到群里。")
        r.expect("live typer: the final text is still written exactly", commaDocument.text, "发布计划，会后我把 release notes 发到群里。")

        // Previews, then the final text: the document follows each one.
        let document = LiveDocument()
        let typer = LiveTyper(sink: document)
        var followed = true
        for preview in ["I will", "I will send the fire", "I will send the file to", "I will send the file to you"] {
            typer.update(to: preview)
            followed = followed && document.text == preview
        }
        typer.update(to: "I will send the file to you")          // nothing new: nothing written
        typer.finish(with: "I will send the file to you.")
        r.step("live typer: the document follows every preview and ends as the final text",
               ok: followed && document.text == "I will send the file to you." && document.mismatches == 0,
               ["edits": "\(document.edits.count)"])
        r.expect("live typer: an unchanged preview writes nothing", typer.updates, 5)

        // Nothing was said after all (the final pass found only silence).
        let silent = LiveDocument()
        let silentTyper = LiveTyper(sink: silent)
        silentTyper.update(to: "Thank you")
        silentTyper.finish(with: "")
        r.expect("live typer: an empty result takes back what was written", silent.text, "")

        // The user clicked or typed part-way: nothing more is deleted.
        let touched = LiveDocument()
        let touchedTyper = LiveTyper(sink: touched)
        touchedTyper.update(to: "send the fire")
        touchedTyper.disturb()
        touchedTyper.update(to: "send the file to")
        r.expect("live typer: after the user steps in, previews are no longer written", touched.text, "send the fire")
        touchedTyper.finish(with: "send the file to you.")
        r.step("live typer: …and the end is only added, never taken back",
               ok: touched.text == "send the firele to you." && touched.edits.allSatisfy { $0.deleted.isEmpty },
               ["text": touched.text])

        // Where corrections (backspaces) are safe.
        // (role, has a text selection, allowed)
        let targets: [(String?, Bool, Bool)] = [
            ("AXTextArea", true, true),
            ("AXTextField", true, true),
            ("AXComboBox", true, true),
            ("AXGroup", true, true),            // a web editor that calls itself a group
            ("AXWebArea", false, true),         // the page itself: a backspace does nothing
            ("AXWindow", false, true),          // the app names no control
            (nil, false, true),                 // the app doesn't answer
            ("AXTable", false, false),          // a list of mail: backspace deletes
            ("AXOutline", false, false),
            ("AXList", false, false),
            ("AXRow", false, false),
            ("AXButton", false, false),
            ("AXGroup", false, false),
            ("AXUnknown", false, false),
        ]
        for (role, editsText, allowed) in targets {
            r.expect("live target: \(role ?? "no answer")\(editsText ? " with a text selection" : "")",
                     LiveTarget.verdict(role: role, editsText: editsText).allowed, allowed)
        }
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
