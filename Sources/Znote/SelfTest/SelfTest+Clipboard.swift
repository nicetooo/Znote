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

        init(_ pasteboard: NSPasteboard) { self.pasteboard = pasteboard }

        func key(_ code: CGKeyCode, down: Bool) {
            guard down else { return }
            if code == 0x08, let selection {            // C
                pasteboard.clearContents()
                pasteboard.setString(selection, forType: .string)
            } else if code == 0x09 {                    // V
                pasted.append(pasteboard.string(forType: .string) ?? "<nothing>")
            }
        }
    }

    static func runClipboard(_ r: inout Report) async {
        let board = NSPasteboard(name: NSPasteboard.Name("com.znote.selftest.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let front = FrontApp(board)
        let system = SystemIntegration(pasteboard: board, postCommandKey: { front.key($0, down: $1) })

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
    }

    private static func tinyPNG() -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        rep?.setColor(.red, atX: 1, y: 1)
        return rep?.representation(using: .png, properties: [:]) ?? Data([0x89, 0x50, 0x4E, 0x47])
    }
}
