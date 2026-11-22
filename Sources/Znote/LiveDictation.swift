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

    init(sink: LiveTextSink) { self.sink = sink }

    func disturb() {
        if !disturbed { log("Live: the user stepped in — nothing more will be taken back") }
        disturbed = true
    }

    /// A newer preview. Ignored once disturbed: previews exist to be
    /// corrected, and corrections are no longer possible.
    func update(to text: String) {
        guard !disturbed else { return }
        write(LiveText.settled(written: written, preview: text))
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
