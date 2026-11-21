import AppKit
import CoreGraphics
import Foundation

/// Reads the selection from, and pastes text into, whichever app is in front —
/// by borrowing the clipboard and simulating ⌘C / ⌘V — then puts the
/// clipboard back the way it was.
///
/// Everything here runs on the main queue without blocking it: the waits
/// between key events are scheduled, not slept.
class SystemIntegration {
    private let pasteboard: NSPasteboard
    /// Presses (true) or releases (false) a key with ⌘ held.
    private let postCommandKey: (CGKeyCode, Bool) -> Void

    private static let keyC: CGKeyCode = 0x08
    private static let keyV: CGKeyCode = 0x09

    /// The defaults are the real clipboard and real key events. The self-test
    /// substitutes a private pasteboard and a stand-in for the front app.
    init(pasteboard: NSPasteboard = .general, postCommandKey: ((CGKeyCode, Bool) -> Void)? = nil) {
        self.pasteboard = pasteboard
        self.postCommandKey = postCommandKey ?? SystemIntegration.postRealKey
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

    // MARK: - Helpers

    private func after(_ seconds: TimeInterval, _ work: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private static func postRealKey(_ keyCode: CGKeyCode, _ down: Bool) {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down) else { return }
        event.flags = .maskCommand
        event.post(tap: .cgAnnotatedSessionEventTap)
    }
}
