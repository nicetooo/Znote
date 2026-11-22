import AppKit

/// Scenario `clipboard` — SystemIntegration's borrow-and-restore of the
/// clipboard around ⌘C / ⌘V, on a private pasteboard with a stand-in for the
/// front app. The real clipboard is never touched and no key events are posted.
extension SelfTest {
    /// Plays the app in front: "copies" its selection on ⌘C, records what it
    /// would have received on ⌘V.
    private final class FrontApp {
        let pasteboard: NSPasteboard
        var selection: String?
        var pasted: [String] = []
        /// The text field the cursor is in: ⌘V adds to it, backspace takes from it.
        var document = ""
        var backspaces = 0

        init(_ pasteboard: NSPasteboard) { self.pasteboard = pasteboard }

        func key(_ code: CGKeyCode, down: Bool) {
            guard down else { return }
            if code == 0x08, let selection {            // C
                pasteboard.clearContents()
                pasteboard.setString(selection, forType: .string)
            } else if code == 0x09 {                    // V
                let text = pasteboard.string(forType: .string)
                pasted.append(text ?? "<nothing>")
                document += text ?? ""
            }
        }

        func plainKey(_ code: CGKeyCode, down: Bool) {
            guard down, code == SystemIntegration.keyBackspace else { return }
            backspaces += 1
            if !document.isEmpty { document.removeLast() }
        }
    }

    static func runClipboard(_ r: inout Report) async {
        let board = NSPasteboard(name: NSPasteboard.Name("com.znote.selftest.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let front = FrontApp(board)
        let system = SystemIntegration(pasteboard: board, postCommandKey: { front.key($0, down: $1) },
                                       postPlainKey: { front.plainKey($0, down: $1) })

        func wait(_ ms: UInt64) async { try? await Task.sleep(nanoseconds: ms * 1_000_000) }
        func selectedText() async -> String? {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { system.getSelectedText { continuation.resume(returning: $0) } }
            }
        }
        func paste(_ text: String) async {
            await MainActor.run { system.pasteText(text) }
        }
        func putImage() -> Data {
            let png = tinyPNG()
            board.clearContents()
            let item = NSPasteboardItem()
            item.setData(png, forType: .png)
            item.setString("caption that travels with the image", forType: .string)
            board.writeObjects([item])
            return png
        }

        // ── Reading the selection ──
        board.clearContents()
        board.setString("previous text", forType: .string)
        front.selection = "selected words"
        var got = await selectedText()
        r.expect("selection: returned", got, "selected words")
        r.expect("selection: text clipboard restored", board.string(forType: .string), "previous text")

        var png = putImage()
        got = await selectedText()
        r.expect("selection: returned (image on clipboard)", got, "selected words")
        r.step("selection: image clipboard restored", ok: board.data(forType: .png) == png,
               ["types": (board.types ?? []).map(\.rawValue).joined(separator: ",")])
        r.expect("selection: image's other representation restored",
                 board.string(forType: .string), "caption that travels with the image")

        front.selection = nil
        let countBefore = board.changeCount
        got = await selectedText()
        r.expect("no selection: returns nil", got, nil)
        r.expect("no selection: clipboard never touched", board.changeCount, countBefore)

        board.clearContents()
        board.writeObjects(["first" as NSString, "second" as NSString])
        front.selection = "selected words"
        _ = await selectedText()
        r.expect("selection: every clipboard item restored", board.pasteboardItems?.count, 2)

        // ── Pasting ──
        png = putImage()
        front.pasted = []
        await paste("dictated sentence")
        await wait(200)
        r.expect("paste: the app receives the text", front.pasted, ["dictated sentence"])
        await wait(600)
        r.step("paste: image clipboard restored afterwards", ok: board.data(forType: .png) == png)

        board.clearContents()
        await paste("dictated sentence")
        await wait(800)
        r.expect("paste: an empty clipboard is left empty", board.string(forType: .string), nil)

        // The user copies something else before the restore fires.
        _ = putImage()
        await paste("dictated sentence")
        await wait(200)
        board.clearContents()
        board.setString("copied by the user meanwhile", forType: .string)
        await wait(600)
        r.expect("paste: a newer copy is not overwritten", board.string(forType: .string), "copied by the user meanwhile")

        await runLiveEdits(&r, board: board, front: front, system: system, putImage: putImage)
    }

    /// Live dictation into the front app: backspaces and pastes, with the
    /// clipboard borrowed once for the whole of it.
    private static func runLiveEdits(_ r: inout Report, board: NSPasteboard, front: FrontApp,
                                     system: SystemIntegration, putImage: () -> Data) async {
        func wait(_ ms: UInt64) async { try? await Task.sleep(nanoseconds: ms * 1_000_000) }
        let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
        func settle() async {
            for _ in 0..<100 {
                if await MainActor.run(body: { system.liveIdle }) { return }
                await wait(20)
            }
        }
        func reset() async {
            await wait(700)                      // the previous restore has fired
            front.document = ""
            front.pasted = []
            front.backspaces = 0
        }

        // The key events themselves — built, never posted.
        let backspace = SystemIntegration.keyEvent(SystemIntegration.keyBackspace, down: true, command: false)
        let paste = SystemIntegration.keyEvent(0x09, down: true, command: true)
        let modifiers: CGEventFlags = [.maskCommand, .maskShift, .maskAlternate, .maskControl]
        r.step("live keys: the backspace carries no modifier at all", ok: backspace?.flags.intersection(modifiers) == [],
               ["flags": String(backspace?.flags.rawValue ?? 0, radix: 16)])
        r.step("live keys: ⌘V carries ⌘ and nothing else", ok: paste?.flags.intersection(modifiers) == .maskCommand)
        // Nothing is held while this runs, so the two above would pass even
        // if the flags were left as created. An event as it comes out while
        // right ⌘ and ⇧ are held (device bits included) must be wiped too.
        let held = CGEvent(keyboardEventSource: nil, virtualKey: SystemIntegration.keyBackspace, keyDown: true)
        held?.flags = CGEventFlags(rawValue: 0x10 | 0x100000 | 0x20000)
        if let held { SystemIntegration.stamp(held, command: false) }
        r.step("live keys: a backspace made while ⌘ and ⇧ are held still carries neither",
               ok: held != nil && held?.flags.intersection(modifiers) == [] && (held?.flags.rawValue ?? 1) & 0x10 == 0,
               ["flags": String(held?.flags.rawValue ?? 0, radix: 16)])
        r.step("live keys: both are marked as Znote's own",
               ok: backspace?.getIntegerValueField(.eventSourceUserData) == SystemIntegration.syntheticEventTag
                && paste?.getIntegerValueField(.eventSourceUserData) == SystemIntegration.syntheticEventTag)

        // Previews one after another, as the live loop delivers them.
        await reset()
        var png = putImage()
        let typer = await MainActor.run { LiveTyper(sink: system) }
        await MainActor.run { typer.update(to: "今天下午开回") }
        await settle()
        r.expect("live: the first preview is pasted", front.document, "今天下午开回")
        r.step("live: the fragment on the clipboard is marked as passing through",
               ok: board.types?.contains(transient) == true)
        await MainActor.run { typer.update(to: "今天下午开会，会后我把 file") }
        await settle()
        r.expect("live: a correction backspaces only what changed", front.backspaces, 1)
        r.expect("live: …and pastes the new ending", front.document, "今天下午开会，会后我把 file")
        await wait(700)
        r.step("live: the clipboard is not given back between previews", ok: board.data(forType: .png) != png)
        await MainActor.run {
            typer.finish(with: "今天下午开会，会后我把文件发给你。")
            system.endLive()
        }
        await settle()
        r.expect("live: the document ends as the final text", front.document, "今天下午开会，会后我把文件发给你。")
        r.expect("live: three pastes in all", front.pasted.count, 3)
        await wait(700)
        r.step("live: the clipboard is given back once, at the end", ok: board.data(forType: .png) == png)

        // Faster than they can be carried out: still in order.
        await reset()
        let burst = await MainActor.run { LiveTyper(sink: system) }
        await MainActor.run {
            burst.update(to: "one two three")
            burst.update(to: "one two tree house")
            burst.finish(with: "one, two, three.")
            system.endLive()
        }
        await settle()
        r.expect("live: edits arriving together are carried out in order", front.document, "one, two, three.")

        // A long take-back is spread over several bursts and still complete.
        await reset()
        let long = String(repeating: "很长的一句话", count: 12)       // 72 characters
        let retract = await MainActor.run { LiveTyper(sink: system) }
        await MainActor.run { retract.update(to: long) }
        await settle()
        await MainActor.run {
            retract.finish(with: "")
            system.endLive()
        }
        await settle()
        r.step("live: an empty result takes back everything, one backspace per character",
               ok: front.document.isEmpty && front.backspaces == 72, ["backspaces": "\(front.backspaces)"])

        // The user copies something while the dictation is going on.
        await reset()
        png = putImage()
        let copying = await MainActor.run { LiveTyper(sink: system) }
        await MainActor.run { copying.update(to: "first part") }
        await settle()
        board.clearContents()
        board.setString("copied by the user meanwhile", forType: .string)
        await MainActor.run {
            copying.finish(with: "first part and the rest.")
            system.endLive()
        }
        await settle()
        r.expect("live: the dictation still lands", front.document, "first part and the rest.")
        await wait(700)
        r.expect("live: what the user copied part-way is what comes back", board.string(forType: .string),
                 "copied by the user meanwhile")

        // …or right after it, before the clipboard is given back.
        await reset()
        _ = putImage()
        let late = await MainActor.run { LiveTyper(sink: system) }
        await MainActor.run {
            late.finish(with: "all at once")
            system.endLive()
        }
        await settle()
        board.clearContents()
        board.setString("copied just after", forType: .string)
        await wait(700)
        r.expect("live: a copy made just after it is not overwritten", board.string(forType: .string), "copied just after")
    }

    private static func tinyPNG() -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        rep?.setColor(.red, atX: 1, y: 1)
        return rep?.representation(using: .png, properties: [:]) ?? Data([0x89, 0x50, 0x4E, 0x47])
    }
}
