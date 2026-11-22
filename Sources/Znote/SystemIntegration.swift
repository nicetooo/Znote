import AppKit
import CoreGraphics
import Foundation

/// Reads the selection from, and pastes text into, whichever app is in front —
/// by borrowing the clipboard and simulating ⌘C / ⌘V — then puts the
/// clipboard back the way it was.
///
/// Everything here runs on the main queue without blocking it: the waits
/// between key events are scheduled, not slept.
class SystemIntegration: LiveTextSink {
    private let pasteboard: NSPasteboard
    /// Presses (true) or releases (false) a key with ⌘ held.
    private let postCommandKey: (CGKeyCode, Bool) -> Void
    /// Presses or releases a key with nothing held.
    private let postPlainKey: (CGKeyCode, Bool) -> Void

    private static let keyC: CGKeyCode = 0x08
    private static let keyV: CGKeyCode = 0x09
    static let keyBackspace: CGKeyCode = 0x33

    /// Carried by every key event Znote posts (`eventSourceUserData`), so
    /// its own key monitor can tell them from the user's: "ZNOTE".
    static let syntheticEventTag: Int64 = 0x5A4E_4F54_45

    /// The defaults are the real clipboard and real key events. The self-test
    /// substitutes a private pasteboard and a stand-in for the front app.
    init(pasteboard: NSPasteboard = .general, postCommandKey: ((CGKeyCode, Bool) -> Void)? = nil,
         postPlainKey: ((CGKeyCode, Bool) -> Void)? = nil) {
        self.pasteboard = pasteboard
        self.postCommandKey = postCommandKey ?? { SystemIntegration.keyEvent($0, down: $1, command: true)?.post(tap: .cgAnnotatedSessionEventTap) }
        self.postPlainKey = postPlainKey ?? { SystemIntegration.keyEvent($0, down: $1, command: false)?.post(tap: .cgAnnotatedSessionEventTap) }
    }

    // MARK: - Clipboard snapshot

    /// Everything on the pasteboard: every item, every representation — so an
    /// image, a file reference or styled text survives being borrowed.
    struct Snapshot {
        fileprivate let items: [[NSPasteboard.PasteboardType: Data]]
    }

    func snapshot() -> Snapshot {
        let items = (pasteboard.pasteboardItems ?? []).map { item -> [NSPasteboard.PasteboardType: Data] in
            var contents: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { contents[type] = data }
            }
            return contents
        }
        return Snapshot(items: items)
    }

    func restore(_ snapshot: Snapshot) {
        pasteboard.clearContents()
        let items = snapshot.items.filter { !$0.isEmpty }.map { contents -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in contents { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { pasteboard.writeObjects(items) }
    }

    // MARK: - Selection

    /// Copy the front app's selection and hand it to `completion` (on the
    /// main queue); nil if nothing was selected. The clipboard is restored
    /// before `completion` runs.
    func getSelectedText(completion: @escaping (String?) -> Void) {
        let saved = snapshot()
        let countBefore = pasteboard.changeCount

        postCommandKey(SystemIntegration.keyC, true)
        after(0.03) {
            self.postCommandKey(SystemIntegration.keyC, false)
            // Give the front app time to put its selection on the clipboard.
            self.after(0.15) {
                guard self.pasteboard.changeCount != countBefore else {
                    completion(nil)   // nothing was copied; clipboard untouched
                    return
                }
                let text = self.pasteboard.string(forType: .string)
                self.restore(saved)
                completion(text?.isEmpty == false ? text : nil)
            }
        }
    }

    // MARK: - Paste

    /// Paste `text` at the cursor of the front app, then restore the clipboard.
    func pasteText(_ text: String) {
        let saved = snapshot()
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let countAfterWrite = pasteboard.changeCount

        // Let the clipboard settle before the paste keystroke.
        after(0.05) {
            self.postCommandKey(SystemIntegration.keyV, true)
            self.after(0.03) {
                self.postCommandKey(SystemIntegration.keyV, false)
                // Restore once the app has read the text — unless something
                // else was copied meanwhile, which we must not overwrite.
                self.after(0.5) {
                    if self.pasteboard.changeCount == countAfterWrite { self.restore(saved) }
                }
            }
        }
    }

    // MARK: - Live dictation

    /// Marks what is on the clipboard as passing through, so clipboard
    /// managers don't keep every fragment (nspasteboard.org).
    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    /// Backspaces are posted this many at a time, a tick apart.
    private static let backspaceBurst = 16

    private var liveEdits: [LiveEdit] = []
    private var liveBusy = false
    private var liveEnding = false
    /// The clipboard as it was before the first fragment went onto it, and
    /// the change count our last write left it at.
    private var liveSaved: Snapshot?
    private var liveChangeCount = 0

    /// Whether every edit handed to `apply` has been carried out.
    var liveIdle: Bool { !liveBusy && liveEdits.isEmpty }

    /// Correct the text written at the front app's cursor: backspaces for
    /// what goes, a paste for what comes. Edits are carried out one after
    /// another, however fast they arrive.
    ///
    /// The clipboard is borrowed once for the whole dictation — from the
    /// first paste until `endLive()` — not once per edit.
    func apply(_ edit: LiveEdit) {
        guard !edit.isEmpty else { return }
        liveEdits.append(edit)
        liveEnding = false
        pumpLive()
    }

    /// The dictation is over: give the clipboard back once the last edit has
    /// been carried out and the app has read it.
    func endLive() {
        liveEnding = true
        pumpLive()
    }

    private func pumpLive() {
        guard !liveBusy else { return }
        guard !liveEdits.isEmpty else {
            if liveEnding { finishLive() }
            return
        }
        liveBusy = true
        let edit = liveEdits.removeFirst()
        backspace(edit.deleted.count) {
            guard !edit.inserted.isEmpty else {
                self.liveBusy = false
                self.pumpLive()
                return
            }
            // Something else was copied since our last fragment (or this is
            // the first one): that is what has to come back at the end.
            if self.liveSaved == nil || self.pasteboard.changeCount != self.liveChangeCount {
                self.liveSaved = self.snapshot()
            }
            self.pasteboard.clearContents()
            self.pasteboard.setString(edit.inserted, forType: .string)
            self.pasteboard.setString("", forType: SystemIntegration.transientType)
            self.liveChangeCount = self.pasteboard.changeCount
            self.after(0.05) {
                self.postCommandKey(SystemIntegration.keyV, true)
                self.after(0.03) {
                    self.postCommandKey(SystemIntegration.keyV, false)
                    // Leave the fragment there until the app has read it.
                    self.after(0.12) {
                        self.liveBusy = false
                        self.pumpLive()
                    }
                }
            }
        }
    }

    private func backspace(_ count: Int, then done: @escaping () -> Void) {
        guard count > 0 else { return done() }
        let burst = min(count, SystemIntegration.backspaceBurst)
        for _ in 0..<burst {
            postPlainKey(SystemIntegration.keyBackspace, true)
            postPlainKey(SystemIntegration.keyBackspace, false)
        }
        after(0.012) { self.backspace(count - burst, then: done) }
    }

    private func finishLive() {
        liveEnding = false
        guard let saved = liveSaved else { return }
        liveSaved = nil
        let count = liveChangeCount
        after(0.5) {
            // Unless a new dictation has borrowed it again, or something
            // else was copied meanwhile — which we must not overwrite.
            guard self.liveSaved == nil, self.liveIdle else {
                if self.liveSaved != nil, self.pasteboard.changeCount == count { self.liveSaved = saved }
                return
            }
            if self.pasteboard.changeCount == count { self.restore(saved) }
        }
    }

    // MARK: - Helpers

    private func after(_ seconds: TimeInterval, _ work: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// A key event that carries exactly the modifiers given here, whatever
    /// keys are physically down: live dictation types while the hotkey — a
    /// ⌘ key, by default — is still held, and a backspace that picked that up
    /// would delete to the start of the line. So the flags are always set,
    /// to nothing if need be, never left as the event was created.
    static func keyEvent(_ keyCode: CGKeyCode, down: Bool, command: Bool) -> CGEvent? {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down) else { return nil }
        stamp(event, command: command)
        return event
    }

    /// Replace whatever modifiers `event` was created with — the ones held
    /// on the keyboard at that moment — and mark it as Znote's own.
    static func stamp(_ event: CGEvent, command: Bool) {
        event.flags = command ? .maskCommand : []
        event.setIntegerValueField(.eventSourceUserData, value: syntheticEventTag)
    }
}
