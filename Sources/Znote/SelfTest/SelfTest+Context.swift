import AppKit
import Carbon
import ApplicationServices

/// Scenario `context` — a diagnostic, not part of the default set: asks the
/// real apps on this Mac where they are (window title, document, page
/// address), the way a selection note would.
///
/// It needs Znote's own Accessibility and Automation grants, so run it through
/// LaunchServices (`selftest/context.sh`), not as a child of a terminal. Two
/// further checks take the keyboard or the screen away from whoever is using
/// the Mac, so they are for that person to run, deliberately — never part of
/// an automated run:
/// `ZNOTE_CONTEXT_PANEL=1` (the note panel, for a second, with real key
/// presses) and `ZNOTE_CONTEXT_OPEN=1` (a tab opened in Chrome). What
/// the apps answer is the user's business: the report records only whether an
/// answer came and what kind (scheme, length), never the titles or addresses.
extension SelfTest {
    static func runContext(_ r: inout Report) {
        let env = ProcessInfo.processInfo.environment
        defer {
            if env["ZNOTE_CONTEXT_PANEL"] == "1" { runLivePanel(&r) }
            if env["ZNOTE_CONTEXT_OPEN"] == "1" { runLiveOpen(&r) }
        }
        r.env["accessibility"] = AXIsProcessTrusted() ? "granted" : "missing"
        r.step("accessibility permission", ok: AXIsProcessTrusted())

        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        let browsers = running.filter { SelectionSourceReader.browserFamily(bundleID: $0.bundleIdentifier) != nil }
        r.env["browsers running"] = browsers.compactMap(\.bundleIdentifier).joined(separator: ", ")

        for app in browsers {
            guard let bundleID = app.bundleIdentifier,
                  let family = SelectionSourceReader.browserFamily(bundleID: bundleID) else { continue }
            let window = SelectionSourceReader.focusedWindow(pid: app.processIdentifier)
            let title = window.flatMap { SelectionSourceReader.string($0, kAXTitleAttribute) }
            let document = window.flatMap { SelectionSourceReader.string($0, kAXDocumentAttribute) }
            let started0 = Date()
            let webArea = window.flatMap { SelectionSourceReader.webAreaURL(in: $0) }
            let webAreaMs = ms(since: started0)
            let viaAccessibility = (document.map(SelectionSourceReader.isUsable) ?? false)
                || (webArea.map(SelectionSourceReader.isUsable) ?? false)

            r.step("\(bundleID): window title over Accessibility", ok: title?.isEmpty == false,
                   ["title": title.map { "\($0.count) chars" } ?? "none", "window": window == nil ? "none" : "found"])
            // Informational: is Accessibility alone enough, or will this
            // browser need the Apple Events question (and its permission)?
            r.step("\(bundleID): page address over Accessibility (informational)", ok: true,
                   ["AXDocument": describe(document), "AXWebArea": "\(describe(webArea)) in \(webAreaMs) ms",
                    "enough": viaAccessibility ? "yes" : "no — falls back to Apple Events"])
            if !viaAccessibility || ProcessInfo.processInfo.environment["ZNOTE_CONTEXT_ASK"] == "1" {
                let started = Date()
                let asked = SelectionSourceReader.runAppleScript(
                    "tell application id \"\(bundleID)\" to get \(family.urlExpression)", timeout: 20)
                r.step("\(bundleID): page address over Apple Events",
                       ok: asked.output.map(SelectionSourceReader.isUsable) ?? false, ms: ms(since: started),
                       ["answer": describe(asked.output), "error": asked.error ?? "-",
                        "same as AXDocument": document != nil && document == asked.output ? "yes" : "no"])
            }

            let started = Date()
            let whole = SelectionSourceReader.read(pid: app.processIdentifier, appName: app.localizedName, bundleID: bundleID)
            r.step("\(bundleID): read() gives a web address", ok: whole.webURL != nil, ms: ms(since: started),
                   ["label length": "\(whole.label.count)"])
        }

        // A few ordinary apps, to see how often AXDocument is there.
        for app in running.filter({ SelectionSourceReader.browserFamily(bundleID: $0.bundleIdentifier) == nil }).prefix(12) {
            let source = SelectionSourceReader.read(pid: app.processIdentifier, appName: app.localizedName,
                                                    bundleID: app.bundleIdentifier)
            r.step("\(app.bundleIdentifier ?? "?") (informational)", ok: true,
                   ["title": source.windowTitle.map { "\($0.count) chars" } ?? "none", "url": describe(source.url)])
        }

        // Live dictation: what each app says has its keyboard focus, and
        // whether text would be written there as it is spoken. Roles only.
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        for app in running.prefix(24) {
            let started = Date()
            let verdict = LiveTarget.check(pid: app.processIdentifier)
            r.step("\(app.bundleIdentifier ?? "?"): keyboard focus (informational)", ok: true, ms: ms(since: started),
                   ["role": verdict.role, "live typing": verdict.allowed ? "yes" : "no — written once, on release",
                    "frontmost": app.processIdentifier == front ? "yes" : "no"])
        }
    }

    // MARK: - On the real screen

    /// Let AppKit deliver real events for a while (this process has no
    /// NSApplication.run loop of its own).
    private static func pump(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if let event = NSApp.nextEvent(matching: .any, until: end, inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
        }
    }

    private static func press(_ key: CGKeyCode, command: Bool = false) {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)
            // Always explicit: left unset, a plain key inherits the ⌘ of the
            // synthetic press before it.
            event?.flags = command ? .maskCommand : []
            event?.post(tap: .cghidEventTap)
        }
    }

    /// `ZNOTE_CONTEXT_PANEL=1`: put the real note panel on screen beside the
    /// pointer for a second and press real keys. The one thing the off-screen
    /// tests can't show: that the panel gets the keyboard while another app
    /// stays in front. Keys are only pressed once the panel is the key window,
    /// so they can't land in the user's app.
    static func runLivePanel(_ r: inout Report) {
        let app = NSApplication.shared
        app.finishLaunching()
        pump(0.3)
        // The system sometimes has no answer for a moment (the app in front
        // is busy); ask again rather than start from "nobody".
        var frontBefore = focusedApp()
        for _ in 0..<10 where frontBefore == nil {
            pump(0.2)
            frontBefore = focusedApp()
        }
        let frontmostBefore = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let menuOwnerBefore = NSWorkspace.shared.menuBarOwningApplication?.processIdentifier
        r.step("live: Znote starts in the background, as it is in real use", ok: !app.isActive && frontBefore != nil,
               ["in front": frontBefore ?? "nobody"])

        let panel = NoteInputPanel()
        var saved: [String] = []
        panel.show(text: "Znote self-test — this panel closes by itself in a moment.",
                   source: SelectionSource(appName: "Znote self-test"), near: NSEvent.mouseLocation,
                   onSave: { saved.append($0) })
        defer { panel.dismiss() }
        pump(0.5)

        let isKey = panel.window?.isKeyWindow ?? false
        let onScreen = panel.window.map { window in NSScreen.screens.contains { $0.frame.contains(window.frame) } } ?? false
        r.step("live: the note panel is on screen", ok: onScreen)
        r.step("live: the panel has the keyboard", ok: isKey && focusedApp() == Bundle.main.bundleIdentifier,
               ["keyboard focus": focusedApp() ?? "nobody", "isKeyWindow": "\(isKey)", "NSApp.isActive": "\(app.isActive)",
                "NSApp.keyWindow is the panel": "\(app.keyWindow === panel.window)",
                "window visible": "\(panel.window?.isVisible ?? false)",
                "occlusion visible": "\(panel.window?.occlusionState.contains(.visible) ?? false)",
                "secure input": "\(IsSecureEventInputEnabled())"])
        // …while the app the user was in keeps its place: still frontmost,
        // still owning the menu bar. (NSApp.isActive is true here — AppKit's
        // own view of having a key window — so it isn't what to look at.)
        r.step("live: Znote was not activated — the same app is frontmost and owns the menu bar",
               ok: NSWorkspace.shared.frontmostApplication?.processIdentifier == frontmostBefore
                && NSWorkspace.shared.menuBarOwningApplication?.processIdentifier == menuOwnerBefore
                && frontmostBefore != ProcessInfo.processInfo.processIdentifier
                && !NSRunningApplication.current.isActive)
        // No key is pressed unless the system itself says the panel has the
        // keyboard — otherwise the presses would land in the user's app.
        guard isKey, focusedApp() == Bundle.main.bundleIdentifier else { return }

        // Dictation: the app asks hasKeyboard, then writes into the note.
        r.step("live: the panel reports having the keyboard, and takes dictated text",
               ok: panel.hasKeyboard && panel.insert("语音") && panel.textView?.string == "语音")
        // ⌘A, ⌘X and ⌘V are answered by the (never shown) Edit menu. The
        // clipboard is the user's: borrowed here, put back below.
        EditMenu.install()
        let clipboard = SystemIntegration()
        let saved_ = clipboard.snapshot()
        defer { clipboard.restore(saved_) }
        press(0, command: true)     // ⌘A
        pump(0.2)
        press(7, command: true)     // ⌘X
        pump(0.3)
        r.step("live: ⌘A then ⌘X empties the note onto the clipboard",
               ok: panel.textView?.string == "" && NSPasteboard.general.string(forType: .string) == "语音")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("pasted", forType: .string)
        press(9, command: true)     // ⌘V
        pump(0.3)
        r.expect("live: ⌘V pastes into the note", panel.textView?.string, "pasted")
        press(6, command: true)     // ⌘Z
        pump(0.3)
        r.expect("live: ⌘Z undoes it", panel.textView?.string, "")

        press(6)        // "z"
        pump(0.5)
        let composing = panel.textView?.hasMarkedText() ?? false
        r.step("live: a real key press lands in the note", ok: panel.textView?.string.lowercased() == "z",
               ["input method composing": "\(composing)"])
        press(36)       // ↵ — an input method that is composing takes the first one
        pump(0.4)
        if saved.isEmpty {
            press(36)
            pump(0.4)
        }
        r.step("live: a real ↵ saves it", ok: saved.count == 1 && saved.first?.lowercased() == "z",
               ["saved": "\(saved.count)", "returns needed": composing ? "2 (the input method took the first)" : "1"])
        pump(0.8)
        r.step("live: the panel closes itself", ok: !panel.isShowing)
        pump(0.3)
        r.expect("live: afterwards the same app is still in front", focusedApp(), frontBefore)
    }

    /// The app that has the keyboard focus right now, asked of the system
    /// (NSWorkspace's answer goes stale in a process without an event loop).
    private static func focusedApp() -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute as CFString,
                                            &value) == .success, let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        var pid: pid_t = 0
        AXUIElementGetPid(value as! AXUIElement, &pid)
        return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "pid \(pid)"
    }

    /// `ZNOTE_CONTEXT_OPEN=1`: really go back to a page — opens one tab in
    /// Chrome — and read back what Chrome then has in front.
    static func runLiveOpen(_ r: inout Report) {
        let bundleID = "com.google.Chrome"
        guard let chrome = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
            r.step("live open: Chrome is running", ok: false)
            return
        }
        let page = "https://en.wikipedia.org/wiki/Speech_recognition"
        let source = SelectionSource(appName: "Google Chrome", bundleID: bundleID, windowTitle: nil, url: page)
        guard let action = SourceRestorer.action(
            for: source, text: "Hidden Markov models (HMMs) are widely used in many systems.") else {
            r.step("live open: there is a way back", ok: false)
            return
        }
        r.step("live open: the page was handed to Chrome", ok: SourceRestorer.perform(action))
        pump(5)
        let now = SelectionSourceReader.read(pid: chrome.processIdentifier, appName: chrome.localizedName, bundleID: bundleID)
        r.step("live open: Chrome's front tab is that page", ok: now.url?.hasPrefix(page) == true,
               ["address": describe(now.url)])
        r.expect("live open: Chrome came to the front", focusedApp(), bundleID)
    }

    /// "https, 87 chars" — enough to judge the answer without recording it.
    private static func describe(_ url: String?) -> String {
        guard let url, !url.isEmpty else { return "none" }
        let scheme = URL(string: url)?.scheme ?? "no scheme"
        return "\(scheme), \(url.count) chars\(url.contains("#") ? ", has fragment" : "")"
    }
}
