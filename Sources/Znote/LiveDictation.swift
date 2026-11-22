import AppKit
import ApplicationServices

/// One change to text that has already been written somewhere: take
/// `deleted` off its end, then add `inserted`.
struct LiveEdit: Equatable {
    let deleted: String
    let inserted: String
    var isEmpty: Bool { deleted.isEmpty && inserted.isEmpty }
}

/// Somewhere live dictation can be written: the app in front (backspaces and
/// paste, `SystemIntegration`) or Znote's own note panel.
protocol LiveTextSink: AnyObject {
    func apply(_ edit: LiveEdit)
}

enum LiveText {
    /// The smallest end-of-text change that turns `written` into `target`:
    /// keep what they have in common from the start, replace the rest.
    static func edit(from written: String, to target: String) -> LiveEdit {
        var w = written.startIndex, t = target.startIndex
        while w < written.endIndex, t < target.endIndex, written[w] == target[t] {
            w = written.index(after: w)
            t = target.index(after: t)
        }
        return LiveEdit(deleted: String(written[w...]), inserted: String(target[t...]))
    }

    /// What to write for a new preview, given what is written already: the
    /// preview, but keeping what is written wherever the two differ only in
    /// punctuation, spacing or capitals. From one pass to the next Whisper
    /// changes its mind about a comma or a capital far more often than about
    /// a word, and each change would otherwise mean backspacing everything
    /// after it and writing it again. The final pass is not softened this
    /// way: it is written exactly.
    static func settled(written: String, preview: String) -> String {
        var w = written.startIndex, p = preview.startIndex
        // Just past the last character the two agreed on.
        var keptWritten = written.startIndex, keptPreview = preview.startIndex
        while true {
            while w < written.endIndex, isFormatting(written[w]) { w = written.index(after: w) }
            while p < preview.endIndex, isFormatting(preview[p]) { p = preview.index(after: p) }
            guard w < written.endIndex, p < preview.endIndex,
                  written[w].lowercased() == preview[p].lowercased() else { break }
            w = written.index(after: w)
            p = preview.index(after: p)
            keptWritten = w
            keptPreview = p
        }
        return String(written[..<keptWritten]) + String(preview[keptPreview...])
    }

    private static func isFormatting(_ character: Character) -> Bool {
        character.isPunctuation || character.isWhitespace
    }

    /// A preview without its last word (its last two characters, in a script
    /// written without spaces). The end of a preview is the word the
    /// recording was cut in the middle of, and the one most often changed by
    /// the next pass — so where nothing written can be taken back, it waits.
    static func withoutLastWord(_ text: String) -> String {
        guard let last = text.unicodeScalars.last else { return text }
        let spaceless = (0x2E80...0x9FFF).contains(last.value) || (0xAC00...0xD7AF).contains(last.value)
            || (0xF900...0xFAFF).contains(last.value) || (0x20000...0x2FFFF).contains(last.value)
        if spaceless { return interim(String(text.dropLast(2))) }
        guard let space = text.lastIndex(where: { $0.isWhitespace }) else { return "" }
        return interim(String(text[..<space]))
    }

    /// The part of `preview` that comes after what is already written, for
    /// where nothing written can be taken back. The two need not agree
    /// word for word: a later pass often changes a word or two of what an
    /// earlier one heard, and that must not stop the text from growing —
    /// the changed words are put right with the final text. `written` is
    /// lined up against the start of `preview` (edit distance) and whatever
    /// follows the best match is the continuation. nil when they are too
    /// different to line up at all.
    static func continuation(written: String, preview: String) -> String? {
        let w = Array(written.lowercased()), p = Array(preview), pl = Array(preview.lowercased())
        guard !w.isEmpty else { return preview }
        guard pl.count == p.count else { return nil }      // a character whose lowercase is longer: don't guess
        // row[j] = edits to turn the written text into the first j characters of the preview.
        var row = Array(0...p.count)
        for i in 1...w.count {
            var previous = row
            swap(&previous, &row)
            row[0] = i
            for j in stride(from: 1, through: p.count, by: 1) {
                let change = previous[j - 1] + (w[i - 1] == pl[j - 1] ? 0 : 1)
                row[j] = min(change, previous[j] + 1, row[j - 1] + 1)
            }
        }
        var best = 0
        for j in 0...p.count where row[j] < row[best] || (row[j] == row[best] && abs(j - w.count) < abs(best - w.count)) {
            best = j
        }
        // Generous: holding a preview back stops the text growing for the
        // rest of the dictation, which is worse than a few wrong characters
        // the final text will put right anyway.
        guard row[best] <= max(4, w.count / 2) else { return nil }
        return String(p[best...])
    }

    /// Whether two previews say the same thing, formatting aside.
    static func sameWords(_ a: String, _ b: String) -> Bool {
        func words(_ text: String) -> String { String(text.lowercased().filter { !isFormatting($0) }) }
        return words(a) == words(b)
    }

    /// A preview as it should be written. Whisper closes whatever it has
    /// heard so far with a full stop, which the next pass takes back when the
    /// sentence turns out to go on — so previews are written without their
    /// closing punctuation, and only the final pass gets to end the sentence.
    static func interim(_ hypothesis: String) -> String {
        var text = Substring(hypothesis)
        while let last = text.last, closing.contains(last) || last.isWhitespace { text = text.dropLast() }
        return String(text)
    }

    private static let closing: Set<Character> = [".", "。", ",", "，", "、", "!", "！", "?", "？", "…", ";", "；", ":", "："]
}

/// Keeps what has been written in step with the latest transcription.
/// Main thread only.
final class LiveTyper {
    private let sink: LiveTextSink
    /// What the sink has been told to write so far.
    private(set) var written = ""
    /// Set once the user did something of their own in the middle of it —
    /// clicked, pressed a key. The cursor may be anywhere now, so nothing
    /// more is taken back: the rest is only ever added.
    private(set) var disturbed = false
    private(set) var updates = 0
    /// Previews that would have meant taking something back, and so were
    /// not written (see `correctsWhileSpeaking`).
    private(set) var held = 0
    private var lastPreview = ""

    /// Whether previews may take back what is written. True only where
    /// writing involves no key events (Znote's own note panel).
    ///
    /// In another app a correction is a backspace, and previews arrive while
    /// the hotkey — a ⌘ key, by default — is physically held: whatever flags
    /// the event carries, the app sees ⌘⌫ and deletes to the start of the
    /// line. So there, while speaking, text is only ever added — what a
    /// preview says beyond what is written, even if it now hears some of
    /// the written words differently — and the one correction comes with
    /// the final text, after the key is up.
    private let correctsWhileSpeaking: Bool

    init(sink: LiveTextSink, correctsWhileSpeaking: Bool) {
        self.sink = sink
        self.correctsWhileSpeaking = correctsWhileSpeaking
    }

    func disturb() {
        if !disturbed { log("Live: the user stepped in — nothing more will be taken back") }
        disturbed = true
    }

    /// A newer preview. Ignored once disturbed: previews exist to be
    /// corrected, and corrections are no longer possible.
    func update(to text: String) {
        guard !disturbed else { return }
        if correctsWhileSpeaking {
            write(LiveText.settled(written: written, preview: text))
            return
        }
        // The last word waits for the next pass to confirm it — unless this
        // pass already says what the one before did (the speaker paused).
        let steady = LiveText.sameWords(text, lastPreview) ? text : LiveText.withoutLastWord(text)
        lastPreview = text
        guard let rest = LiveText.continuation(written: written, preview: steady) else {
            held += 1
            return
        }
        if !rest.isEmpty { write(written + rest) }
    }

    /// The final text. Normally what was written is corrected into it; once
    /// disturbed, only what is missing from the end is added.
    func finish(with text: String) {
        if disturbed {
            let rest = LiveText.edit(from: written, to: text).inserted
            if !rest.isEmpty { sink.apply(LiveEdit(deleted: "", inserted: rest)) }
            written = text
        } else {
            write(text)
        }
    }

    private func write(_ text: String) {
        let edit = LiveText.edit(from: written, to: text)
        guard !edit.isEmpty else { return }
        sink.apply(edit)
        written = text
        updates += 1
    }
}

/// Whether the place the cursor is in can be typed into and corrected
/// safely. Corrections are backspaces: in a text field they take back what
/// was just written, in a list of mail they delete the selected message.
enum LiveTarget {
    struct Verdict: Equatable {
        let allowed: Bool
        /// The focused element's role, or why there is none. For the log.
        let role: String
    }

    /// - Parameters:
    ///   - role: the focused element's AXRole; nil when the app named none.
    ///   - editsText: whether it has a text selection (`AXSelectedTextRange`),
    ///     which is what text fields, text views, web inputs and terminals
    ///     have in common whatever role they report.
    static func verdict(role: String?, editsText: Bool) -> Verdict {
        guard let role else { return Verdict(allowed: true, role: "none") }
        // The window, the app or the page itself: no control has the
        // keyboard as far as the app will say (Electron apps say this until
        // an assistive app asks for more). A backspace there does nothing.
        let vague: Set<String> = ["AXWindow", "AXApplication", "AXWebArea"]
        return Verdict(allowed: editsText || vague.contains(role), role: role)
    }

    /// Ask `pid` what has its keyboard focus. Blocks for as long as the app
    /// takes to answer (at most `timeout`): call it off the main thread.
    static func check(pid: pid_t, timeout: Float = 0.4) -> Verdict {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return verdict(role: nil, editsText: false)
        }
        let element = value as! AXUIElement
        AXUIElementSetMessagingTimeout(element, timeout)
        var roleValue: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue)
        var range: CFTypeRef?
        let editsText = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &range) == .success
        return verdict(role: roleValue as? String ?? "AXUnknown", editsText: editsText)
    }
}

/// Transcribes a recording while it is still being made, over and over, and
/// hands each result to `onText`.
///
/// Whisper is not a streaming model: every pass decodes everything recorded
/// so far, so text arrives about once per pass (a second or two) and earlier
/// words can change.
final class LiveDictation {
    /// Nothing is tried before this much has been recorded.
    static let firstPassAfter: TimeInterval = 1.0
    /// A new pass needs at least this much new audio.
    static let minimumNewAudio: TimeInterval = 0.4

    private var task: Task<Void, Never>?
    private(set) var passes = 0

    /// - Parameters:
    ///   - audio: the recording so far.
    ///   - threshold: the silence gate — previews wait until something this loud was heard.
    ///   - onText: called on the main actor with each preview.
    func start(whisper: WhisperService, translate: Bool, threshold: Float,
               audio: @escaping () -> AudioRecorder.Snapshot,
               onText: @escaping @MainActor (String) -> Void) {
        task?.cancel()
        passes = 0
        task = Task.detached(priority: .userInitiated) { [weak self] in
            var covered: TimeInterval = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 120_000_000)
                guard !Task.isCancelled, whisper.isModelReady, !whisper.isLoading else { continue }
                let snapshot = audio()
                let duration = snapshot.duration
                guard duration >= LiveDictation.firstPassAfter,
                      duration - covered >= LiveDictation.minimumNewAudio,
                      duration < AudioRecorder.liveSecondsLimit,
                      snapshot.peak >= threshold else { continue }
                covered = duration
                let samples = WhisperService.resample(snapshot.samples, from: snapshot.sampleRate)
                guard let text = await whisper.transcribePreview(samples: samples, translate: translate),
                      !Task.isCancelled else { continue }
                self?.passes += 1
                await MainActor.run {
                    // Checked again here: `stop()` may have been called
                    // while this was waiting for the main thread.
                    if !Task.isCancelled { onText(LiveText.interim(text)) }
                }
            }
        }
    }

    /// Stop previewing and wait until the pass in flight has let go of the
    /// model. Nothing reaches `onText` after this returns.
    func stop() async {
        task?.cancel()
        await task?.value
        task = nil
    }
}
