import AppKit

/// Scenario `notes` — selection notes: the scroll-to-text links, where a
/// selection came from and how to get back there, the Translate / Note menu
/// and the note panel (clicked and typed into through NSWindow.sendEvent, in
/// windows ordered in far off every display), and the round trip through the
/// history store. Nothing is opened, no app is asked anything, and the store
/// is the scenario's own.
extension SelfTest {
    static func runNotes(_ request: Request, _ r: inout Report) {
        _ = NSApplication.shared
        runNoteLinks(&r)
        runNoteSources(&r)
        runSelectionMenu(request, &r)
        runNotePanel(request, &r)
        runNotesInHistory(request, &r)
        writeLinkSamples(request, &r)
        runProcessingWave(request, &r)
    }

    /// The recording overlay's bars while a recording is being transcribed:
    /// three moments of the wave, one above the other, in `processing-wave.png`.
    private static func runProcessingWave(_ request: Request, _ r: inout Report) {
        let size = NSSize(width: 280, height: 56)
        let sheet = NSView(frame: NSRect(x: 0, y: 0, width: size.width, height: size.height * 3))
        sheet.wantsLayer = true
        sheet.layer?.backgroundColor = NSColor(white: 0.10, alpha: 1).cgColor
        let window = NSWindow(contentRect: NSRect(origin: offscreen, size: sheet.frame.size), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.contentView = sheet
        var moved = true
        var tallest: [Int] = []
        for row in 0..<3 {
            let wave = WaveformView(frame: NSRect(x: 0, y: CGFloat(row) * size.height, width: size.width, height: size.height))
            wave.processing = true
            wave.phase = CGFloat(row) * 2.0
            sheet.addSubview(wave)
            // Let the bars ease into the wave, as they do over the first frames on screen.
            var first: Data?
            for frame in 0..<30 {
                let data = snapshot(wave)
                if frame == 20 { first = data }
                if frame == 29 { moved = moved && data != nil && data != first }
            }
            tallest.append(row)
        }
        let written = (snapshot(sheet).map { (try? $0.write(to: request.dir.appendingPathComponent("processing-wave.png"))) != nil }) ?? false
        r.step("overlay: while transcribing the bars keep moving (processing-wave.png)", ok: moved && written,
               ["rows": "\(tallest.count)"])
    }

    // MARK: - Notes in the History panel

    /// The notes `runNotePanel` saved, as the History panel lists them, and
    /// its "Go to source" button — clicked for real, with the opening itself
    /// replaced by a recorder.
    private static func runNotesInHistory(_ request: Request, _ r: inout Report) {
        let history = HistoryWindowController()
        var opened: [SourceRestorer.Action] = []
        history.performRestore = { opened.append($0); return true }
        history.showHistory(live: false)
        guard let window = history.window, let content = window.contentView else {
            r.step("history: panel built", ok: false)
            return
        }
        window.setFrameOrigin(offscreen)
        window.orderFront(nil)

        let notes = HistoryStore.shared.fetch(typeFilter: .note)
        history.selectFilter(.note)
        content.layoutSubtreeIfNeeded()
        r.expect("history: the Notes filter lists the notes", history.rowCount, notes.count)
        r.step("history: no row selected → no Go to source button", ok: history.sourceButton?.isHidden == true)

        guard let withSource = notes.firstIndex(where: { $0.restoreAction != nil }),
              let bare = notes.firstIndex(where: { $0.restoreAction == nil }) else {
            r.step("history: a note with a source and one without", ok: false)
            return
        }
        history.toggleRow(withSource)
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))     // the row's height animates
        content.layoutSubtreeIfNeeded()
        let button = history.sourceButton
        let frame = button.map { $0.convert($0.bounds, to: content) } ?? .zero
        r.step("history: selecting a note that knows its source shows the button, inside the panel",
               ok: button?.isHidden == false && frame.width > 40 && content.bounds.contains(frame),
               ["frame": "\(frame)"])
        if let data = snapshot(content) { try? data.write(to: request.dir.appendingPathComponent("history-notes.png")) }

        click(button)
        r.expect("history: clicking it goes back to that note's source", opened, [notes[withSource].restoreAction].compactMap { $0 })
        r.step("history: …and gets the panel out of the way", ok: history.window == nil)

        // The source line in the expanded row is itself a link.
        func reopen(expanding row: Int) -> NSView? {
            history.showHistory(live: false)
            history.window?.setFrameOrigin(offscreen)
            history.window?.orderFront(nil)
            history.selectFilter(.note)
            history.toggleRow(row)
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            history.window?.contentView?.layoutSubtreeIfNeeded()
            return history.window?.contentView
        }
        func links(in view: NSView?) -> [SourceLinkView] {
            guard let view else { return [] }
            return view.subviews.flatMap { ($0 as? SourceLinkView).map { [$0] } ?? links(in: $0) }
        }
        opened = []
        let link = links(in: reopen(expanding: withSource)).first
        r.step("history: the expanded note shows where it came from, as a link, sized to its words",
               ok: link?.onClick != nil && (link?.bounds.width ?? 0) > 60 && (link?.bounds.width ?? 999) < 400
                && (link?.bounds.height ?? 0) >= 14,
               ["size": "\(link?.bounds.size ?? .zero)"])
        click(link)
        r.expect("history: clicking that line goes back to the source too", opened,
                 [notes[withSource].restoreAction].compactMap { $0 })
        r.step("history: …and the panel gets out of the way", ok: history.window == nil)

        let bareContent = reopen(expanding: bare)
        r.step("history: a note without a source has no button and no source line",
               ok: history.sourceButton?.isHidden == true && links(in: bareContent).isEmpty)
        history.hideHistory()
    }

    /// For checking the links against a real browser: with
    /// `ZNOTE_LINK_SAMPLES=<file>` (a JSON array of {"page", "text"}), write
    /// the link Znote would open for each to `<dir>/links.json`.
    private static func writeLinkSamples(_ request: Request, _ r: inout Report) {
        struct Sample: Decodable { let page: String; let text: String }
        guard let path = ProcessInfo.processInfo.environment["ZNOTE_LINK_SAMPLES"], !path.isEmpty else { return }
        guard let data = FileManager.default.contents(atPath: path),
              let samples = try? JSONDecoder().decode([Sample].self, from: data) else {
            r.step("link samples: readable", ok: false, ["file": path])
            return
        }
        let links = samples.map { sample in
            URL(string: sample.page).map { TextFragment.url($0, highlighting: sample.text).absoluteString } ?? ""
        }
        let written = (try? JSONEncoder().encode(links).write(to: request.dir.appendingPathComponent("links.json"))) != nil
        r.step("link samples: written", ok: written && !links.contains(""), ["count": "\(links.count)"])
    }

    // MARK: - Scroll-to-text links

    private static func runNoteLinks(_ r: inout Report) {
        func directive(_ text: String) -> String { TextFragment.directive(for: text) ?? "nil" }

        r.expect("link: short selection is matched whole", directive("Hello world"), "text=Hello%20world")
        r.expect("link: '-', ',' and '&' are encoded (they are syntax)", directive("a-b, c&d"), "text=a%2Db%2C%20c%26d")
        r.expect("link: runs of whitespace collapse", directive("  Hello \t  world "), "text=Hello%20world")
        r.expect("link: nothing to find → no directive", TextFragment.directive(for: " \n\t "), nil)

        let chinese = "我们今天就先讨论到这里。"
        let encoded = directive(chinese)
        r.step("link: Chinese is percent-encoded UTF-8", ok: encoded.allSatisfy(\.isASCII)
                && encoded.dropFirst(5).removingPercentEncoding == chinese, ["directive": encoded])

        r.expect("link: several paragraphs → from the first words to the last",
                 directive("First paragraph of the selection here.\n\nSecond paragraph ends with these words."),
                 "text=First%20paragraph%20of%20the%20selection,paragraph%20ends%20with%20these%20words.")

        let long = "The quick brown fox jumps over the lazy dog while the cat watches from the windowsill above."
        r.expect("link: a long line → its first and last words", directive(long),
                 "text=The%20quick%20brown%20fox%20jumps,from%20the%20windowsill%20above.")

        // Each end is cut between words, never inside one.
        let prose = "这是一段比较长的中文内容，用来检查开头和结尾是不是都切在词的边界上，而不是把一个词从中间劈开；"
            + "只有切在词与词之间，浏览器才会承认这是一处匹配，然后滚动到那里并把它高亮出来，否则它只会停在页面顶部。"
        r.step("link: (the Chinese sample is long enough to need two ends)", ok: prose.count > TextFragment.exactLimit)
        let parts = directive(prose).dropFirst(5).split(separator: ",").map { String($0).removingPercentEncoding ?? "" }
        var boundaries: Set<Int> = [0, prose.count]
        prose.enumerateSubstrings(in: prose.startIndex..., options: [.byWords, .substringNotRequired]) { _, range, _, _ in
            boundaries.insert(prose.distance(from: prose.startIndex, to: range.lowerBound))
            boundaries.insert(prose.distance(from: prose.startIndex, to: range.upperBound))
        }
        r.step("link: long Chinese is cut at word boundaries", ok: parts.count == 2
                && prose.hasPrefix(parts[0]) && prose.hasSuffix(parts[1])
                && boundaries.contains(parts[0].count) && boundaries.contains(prose.count - parts[1].count)
                && parts[0].count >= TextFragment.anchorMinCharacters && parts[1].count >= TextFragment.anchorMinCharacters,
               ["start": parts.first ?? "", "end": parts.last ?? ""])

        let unbroken = String(repeating: "x", count: 90)
        r.expect("link: one long unbroken token is matched whole", directive(unbroken), "text=" + unbroken)

        func link(_ page: String, _ text: String = "Hello") -> String {
            URL(string: page).map { TextFragment.url($0, highlighting: text).absoluteString } ?? "bad url"
        }
        r.expect("link: appended to a plain address", link("https://example.com/page?q=1"), "https://example.com/page?q=1#:~:text=Hello")
        r.expect("link: an existing #fragment is kept", link("https://example.com/page#section"), "https://example.com/page#section:~:text=Hello")
        r.expect("link: a single-page app's route is kept", link("https://app.example.com/#/notes/42"), "https://app.example.com/#/notes/42:~:text=Hello")
        r.expect("link: an earlier directive is replaced", link("https://example.com/page#:~:text=old%20words"), "https://example.com/page#:~:text=Hello")
        r.expect("link: … also after a fragment", link("https://example.com/page#top:~:text=old"), "https://example.com/page#top:~:text=Hello")
        r.expect("link: nothing to find → address unchanged", link("https://example.com/page", "  "), "https://example.com/page")
    }

    // MARK: - Where a selection came from, and the way back

    private static func runNoteSources(_ r: inout Report) {
        let page = SelectionSource(appName: "Google Chrome", bundleID: "com.google.Chrome",
                                   windowTitle: "Znote — notes", url: "https://www.example.com/docs/page")
        let file = SelectionSource(appName: "TextEdit", bundleID: "com.apple.TextEdit",
                                   windowTitle: "notes.txt", url: "file:///Users/someone/Documents/notes.txt")
        let chat = SelectionSource(appName: "Slack", bundleID: "com.tinyspeck.slackmacgap", windowTitle: "#general", url: nil)

        r.expect("source: web page label (www dropped)", page.label, "example.com · Znote — notes")
        r.expect("source: document label", file.label, "notes.txt · TextEdit")
        r.expect("source: app label", chat.label, "Slack · #general")
        r.expect("source: app only", SelectionSource(appName: "Finder").label, "Finder")
        r.step("source: page and file are told apart", ok: page.webURL != nil && page.fileURL == nil
                && file.fileURL?.path == "/Users/someone/Documents/notes.txt" && file.webURL == nil)

        r.expect("reader: Chrome is a Chromium browser", SelectionSourceReader.browserFamily(bundleID: "com.google.Chrome"), .chromium)
        r.expect("reader: Safari", SelectionSourceReader.browserFamily(bundleID: "com.apple.Safari"), .safari)
        r.expect("reader: TextEdit is not a browser", SelectionSourceReader.browserFamily(bundleID: "com.apple.TextEdit"), nil)
        r.step("reader: only addresses that can be reopened are kept",
               ok: SelectionSourceReader.isUsable("https://example.com/") && SelectionSourceReader.isUsable("file:///tmp/a.txt")
                && !SelectionSourceReader.isUsable("about:blank") && !SelectionSourceReader.isUsable("chrome://settings/")
                && !SelectionSourceReader.isUsable("not a url"))

        let text = "first line of the selection\nsecond line"
        r.expect("way back: a page opens scrolled to the selection, in the same browser",
                 SourceRestorer.action(for: page, text: "Hello"),
                 .openPage(URL(string: "https://www.example.com/docs/page#:~:text=Hello")!, bundleID: "com.google.Chrome"))
        r.expect("way back: a document opens in its app, selection ready for ⌘G",
                 SourceRestorer.action(for: file, text: text, fileExists: { _ in true }),
                 .openDocument(URL(string: "file:///Users/someone/Documents/notes.txt")!, bundleID: "com.apple.TextEdit",
                               find: "first line of the selection"))
        r.expect("way back: a document that is gone → its app",
                 SourceRestorer.action(for: file, text: text, fileExists: { _ in false }),
                 .activateApp(bundleID: "com.apple.TextEdit", find: "first line of the selection"))
        r.expect("way back: an app without a document → the app",
                 SourceRestorer.action(for: chat, text: text),
                 .activateApp(bundleID: "com.tinyspeck.slackmacgap", find: "first line of the selection"))
        r.expect("way back: nothing known → nowhere to go",
                 SourceRestorer.action(for: SelectionSource(windowTitle: "Untitled"), text: text), nil)

        // Placement beside the pointer.
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = NSSize(width: 200, height: 44)
        func origin(_ x: CGFloat, _ y: CGFloat) -> String {
            "\(SelectionMenu.origin(nearPointer: NSPoint(x: x, y: y), size: size, screen: screen))"
        }
        r.expect("placement: below and right of the pointer", origin(500, 500), "\(NSPoint(x: 512, y: 444))")
        r.expect("placement: above when there's no room below", origin(500, 30), "\(NSPoint(x: 512, y: 42))")
        r.expect("placement: kept on screen at the right edge", origin(1400, 500), "\(NSPoint(x: 1232, y: 444))")
        r.expect("placement: kept on screen at the top-left corner", origin(-50, 2000), "\(NSPoint(x: 8, y: 848))")
    }

    // MARK: - The Translate / Note menu

    /// A picture of a view that is in a window, as AppKit itself draws it —
    /// layer backgrounds, flipped text views and tinted symbols included.
    private static func snapshot(_ view: NSView) -> Data? {
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    private static let offscreen = NSPoint(x: -30000, y: -30000)

    private static func click(_ view: NSView?) {
        guard let view else { return }
        let middle = NSPoint(x: view.bounds.midX, y: view.bounds.midY)
        mouse(.leftMouseDown, in: view, at: middle)
        mouse(.leftMouseUp, in: view, at: middle)
    }

    private static func runSelectionMenu(_ request: Request, _ r: inout Report) {
        let menu = SelectionMenu()
        var chosen: [SelectionMenu.Choice] = []
        var dismissed = 0
        func open() {
            menu.show(near: offscreen, live: false, onChoose: { chosen.append($0) }, onDismiss: { dismissed += 1 })
            menu.window?.orderFront(nil)
        }

        open()
        guard let window = menu.window, let content = window.contentView,
              let translate = menu.translateButton, let note = menu.noteButton, let close = menu.closeButton else {
            r.step("menu: built", ok: false)
            return
        }
        let onAnyScreen = NSScreen.screens.contains { $0.frame.intersects(window.frame) }
        r.step("menu: ordered in, off every display", ok: window.isVisible && !onAnyScreen, ["frame": "\(window.frame)"])
        r.step("menu: Translate · Note · ✕ side by side, inside the panel",
               ok: translate.frame.maxX <= note.frame.minX && note.frame.maxX <= close.frame.minX
                && content.bounds.contains(translate.frame) && content.bounds.contains(close.frame),
               ["width": "\(content.bounds.width)"])
        r.step("menu: never takes the keyboard", ok: !window.canBecomeKey)
        if let data = snapshot(content) { try? data.write(to: request.dir.appendingPathComponent("selection-menu.png")) }

        click(translate)
        r.step("menu: clicking Translate chooses it and closes the menu", ok: chosen == [.translate] && !menu.isShowing)

        open()
        click(menu.noteButton)
        r.step("menu: clicking Note chooses it", ok: chosen == [.translate, .note] && !menu.isShowing)

        open()
        click(menu.closeButton)
        r.step("menu: ✕ closes without choosing", ok: chosen.count == 2 && dismissed == 1 && !menu.isShowing)

        open()
        menu.chooseDefault()
        r.step("menu: a second tap of the hotkey means Translate", ok: chosen.last == .translate && chosen.count == 3)

        menu.chooseDefault()
        r.step("menu: nothing happens once it's gone", ok: chosen.count == 3 && dismissed == 1)
    }

    // MARK: - The note panel

    private static func key(_ code: UInt16, shift: Bool = false, in window: NSWindow) {
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: shift ? [.shift] : [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: code == 53 ? "\u{1b}" : "\r", charactersIgnoringModifiers: code == 53 ? "\u{1b}" : "\r",
            isARepeat: false, keyCode: code) else { return }
        window.sendEvent(event)
    }

    private static func runNotePanel(_ request: Request, _ r: inout Report) {
        let store = HistoryStore.shared     // the scenario's own database
        r.expect("store: starts empty (not the user's history)", store.count, 0)

        let selection = "Text fragments let a link point at a piece of text."
        let source = SelectionSource(appName: "Google Chrome", bundleID: "com.google.Chrome",
                                     windowTitle: "Example Domain", url: "https://example.com/guide")
        let panel = NoteInputPanel()
        var saved: [String] = []
        var cancelled = 0
        func open(source: SelectionSource? = source) {
            panel.show(text: selection, source: source, near: offscreen, live: false,
                       onSave: { saved.append($0); store.addNote(text: selection, note: $0, source: source) },
                       onCancel: { cancelled += 1 })
            panel.window?.orderFront(nil)
        }
        func type(_ text: String) {
            panel.textView?.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        }

        open()
        guard let window = panel.window, let editor = panel.textView else {
            r.step("note panel: built", ok: false)
            return
        }
        r.step("note panel: can take the keyboard, and the cursor starts in the note",
               ok: window.canBecomeKey && window.firstResponder === editor)
        r.expect("note panel: says where the selection came from", panel.sourceLabel?.stringValue, "↗ example.com · Example Domain")
        if let content = panel.content, let data = snapshot(content) {
            try? data.write(to: request.dir.appendingPathComponent("note-panel-empty.png"))
        }

        type("worth reading")
        key(36, shift: true, in: window)
        type("second line")
        r.expect("note panel: ⇧↵ starts a new line", editor.string, "worth reading\nsecond line")
        if let content = panel.content, let data = snapshot(content) {
            try? data.write(to: request.dir.appendingPathComponent("note-panel.png"))
        }

        key(36, in: window)
        r.expect("note panel: ↵ saves what was typed", saved, ["worth reading\nsecond line"])
        key(36, in: window)
        r.expect("note panel: a second ↵ doesn't save twice", saved.count, 1)
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        r.step("note panel: closes itself after saving", ok: !panel.isShowing)

        // What was saved, as History will show it.
        let record = store.fetch(typeFilter: .note).first
        r.step("saved note: the selection, the note and the source", ok: record?.outputText == selection
                && record?.note == "worth reading\nsecond line" && record?.source == source)
        r.expect("saved note: shown as the note, then the selection quoted",
                 record?.displayText, "worth reading\nsecond line\n“\(selection)”")
        r.expect("saved note: copied with its address",
                 record?.copyText, "worth reading\nsecond line\n\(selection)\nhttps://example.com/guide")
        r.expect("saved note: its way back is the page, scrolled to the selection", record?.restoreAction,
                 .openPage(URL(string: "https://example.com/guide#:~:text=Text%20fragments%20let%20a%20link%20point%20at%20a%20piece%20of%20text.")!,
                           bundleID: "com.google.Chrome"))
        r.expect("saved note: found by what it says", store.fetch(query: "worth reading").count, 1)
        r.expect("saved note: found by the page's title", store.fetch(query: "Example Domain").count, 1)

        // Dictated text is written straight into the note, where the cursor is.
        open()
        type("heard: ")
        r.step("note panel: dictated text goes in at the cursor", ok: panel.insert("试试这个输入")
                && panel.textView?.string == "heard: 试试这个输入")
        panel.textView?.setSelectedRange(NSRange(location: 0, length: 7))
        panel.insert("说：")
        r.expect("note panel: …replacing whatever is selected", panel.textView?.string, "说：试试这个输入")
        r.step("note panel: off screen and not key, it does not claim the keyboard", ok: !panel.hasKeyboard)

        // Live dictation: the note is corrected in place as previews change.
        panel.textView?.string = ""
        type("记一下：")
        let liveTyper = LiveTyper(sink: panel, correctsWhileSpeaking: true)
        liveTyper.update(to: "这个方法可以")
        liveTyper.update(to: "这个方案可以先在 staging")
        r.expect("note panel: a live preview is corrected in place", panel.textView?.string, "记一下：这个方案可以先在 staging")
        liveTyper.finish(with: "这个方案可以先在 staging 上试一下。")
        r.expect("note panel: …and ends as the final text, after what was typed before",
                 panel.textView?.string, "记一下：这个方案可以先在 staging 上试一下。")
        // The user moved the cursor away: what was written is not in front of it any more.
        panel.textView?.setSelectedRange(NSRange(location: 0, length: 0))
        panel.apply(LiveEdit(deleted: "上试一下。", inserted: "【】"))
        r.expect("note panel: nothing is deleted when the text before the cursor isn't what was written",
                 panel.textView?.string, "【】记一下：这个方案可以先在 staging 上试一下。")
        panel.cancel()
        r.step("note panel: nothing is written once it has closed", ok: !panel.insert("too late") && cancelled == 1)
        cancelled = 0

        // esc throws the note away.
        open()
        type("never mind")
        if let window = panel.window { key(53, in: window) }
        r.step("note panel: esc cancels and saves nothing", ok: cancelled == 1 && saved.count == 1 && !panel.isShowing
                && store.count == 1)

        // Nothing typed: the selection and its place are still worth keeping.
        open(source: nil)
        r.expect("note panel: no source line when the source is unknown", panel.sourceLabel?.stringValue, nil)
        if let window = panel.window { key(36, in: window) }
        r.step("note panel: ↵ with nothing typed saves a bare bookmark",
               ok: saved.count == 2 && saved.last == "" && store.fetch(typeFilter: .note).first?.note == nil)

        // The Save and ✕ buttons do the same through the mouse.
        open()
        type("clicked")
        click(panel.content?.subviews.compactMap { $0 as? PickerButton }.first)      // Save is added first
        r.expect("note panel: clicking Save saves", saved.last, "clicked")
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        open()
        click(panel.content?.subviews.compactMap { $0 as? PickerButton }.last)       // then ✕
        r.step("note panel: clicking ✕ cancels", ok: cancelled == 2 && !panel.isShowing && saved.count == 3)

        let written = ["selection-menu.png", "note-panel-empty.png", "note-panel.png"].filter {
            FileManager.default.fileExists(atPath: request.dir.appendingPathComponent($0).path)
        }
        r.step("renders written for review", ok: written.count == 3, ["files": written.joined(separator: ", ")])
    }
}
