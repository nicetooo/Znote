import AppKit

/// Scenario `editor` — screenshot annotation and the History hover preview,
/// without a screen. A synthetic "screenshot" is annotated with every tool
/// through the canvas's own interaction path, flattened, and checked pixel by
/// pixel. The canvas, toolbar and preview card are also rendered to PNG in
/// the scenario directory for a human (or an agent) to look at.
extension SelfTest {
    private static let basePointSize = NSSize(width: 400, height: 300)
    private static let baseScale = 2
    /// Fine black/white stripes here: pixellating them must yield grey.
    private static let stripes = NSRect(x: 40, y: 40, width: 160, height: 100)

    static func runEditor(_ request: Request, _ r: inout Report) {
        _ = NSApplication.shared   // panels and text fields need an application object

        // ── A screenshot to work on: 400×300 pt at 2× ──
        let baseURL = request.dir.appendingPathComponent("base.png")
        guard let basePNG = makeBaseImage(), (try? basePNG.write(to: baseURL)) != nil,
              let baseRep = NSBitmapImageRep(data: basePNG),
              let document = AnnotationDocument(contentsOf: baseURL) else {
            r.errors.append("couldn't create the base image")
            return
        }
        r.expect("document: point size", "\(document.size)", "\(basePointSize)")
        r.expect("document: pixel size", "\(document.pixelSize)",
                 "\(NSSize(width: basePointSize.width * 2, height: basePointSize.height * 2))")

        // ── Draw with every tool through the canvas (view coords == document coords here) ──
        let canvas = AnnotationCanvasView(document: document)
        func drag(_ tool: AnnotationTool, color: Int, width: Int = 1, _ points: [NSPoint]) {
            canvas.tool = tool
            canvas.style = AnnotationStyle(color: AnnotationStyle.colors[color], lineWidth: AnnotationStyle.lineWidths[width])
            guard let first = points.first, let last = points.last else { return }
            canvas.begin(at: first)
            for p in points.dropFirst() { canvas.drag(to: p) }
            canvas.end(at: last)
        }
        let red = 0, yellow = 1, green = 2, blue = 3, black = 5

        drag(.rectangle, color: red, [NSPoint(x: 220, y: 180), NSPoint(x: 360, y: 260)])
        drag(.ellipse, color: blue, [NSPoint(x: 220, y: 40), NSPoint(x: 360, y: 140)])
        drag(.arrow, color: green, [NSPoint(x: 40, y: 270), NSPoint(x: 180, y: 200)])
        drag(.pen, color: yellow, width: 2, [20, 60, 100, 140, 180].map { NSPoint(x: $0, y: 170) })
        canvas.tool = .text
        canvas.style = AnnotationStyle(color: AnnotationStyle.colors[black], lineWidth: AnnotationStyle.lineWidths[1])
        canvas.addText("Znote 标注", at: NSPoint(x: 230, y: 296))
        drag(.mosaic, color: red, [stripes.origin, NSPoint(x: stripes.maxX, y: stripes.maxY)])
        r.expect("canvas: six marks recorded", document.annotations.count, 6)

        // A stray click must not leave a mark (the pen is the exception).
        drag(.rectangle, color: red, [NSPoint(x: 300, y: 20), NSPoint(x: 301, y: 21)])
        r.expect("canvas: 1 pt drag adds nothing", document.annotations.count, 6)

        // ── Flatten and inspect ──
        guard let png = document.renderPNG(), let out = NSBitmapImageRep(data: png) else {
            r.errors.append("renderPNG returned nothing")
            return
        }
        try? png.write(to: request.dir.appendingPathComponent("annotated.png"))
        r.expect("export: keeps pixel resolution", "\(out.pixelsWide)×\(out.pixelsHigh)", "\(baseRep.pixelsWide)×\(baseRep.pixelsHigh)")
        r.expect("export: keeps point size (DPI)", "\(out.size)", "\(basePointSize)")

        func check(_ name: String, at p: NSPoint, is want: NSColor) {
            let got = pixel(out, at: p)
            r.step(name, ok: close(got, rgb(want)), ["at": "\(p)", "got": describe(got), "want": describe(rgb(want))])
        }
        func checkUnchanged(_ name: String, at p: NSPoint) {
            let got = pixel(out, at: p), want = pixel(baseRep, at: p)
            r.step(name, ok: close(got, want), ["at": "\(p)", "got": describe(got), "base": describe(want)])
        }
        check("rectangle: edge is red", at: NSPoint(x: 290, y: 180), is: AnnotationStyle.colors[red])
        checkUnchanged("rectangle: inside is untouched", at: NSPoint(x: 290, y: 220))
        check("ellipse: rim is blue", at: NSPoint(x: 360, y: 90), is: AnnotationStyle.colors[blue])
        checkUnchanged("ellipse: inside is untouched", at: NSPoint(x: 290, y: 90))
        check("arrow: shaft is green", at: NSPoint(x: 110, y: 235), is: AnnotationStyle.colors[green])
        check("arrow: head is green", at: NSPoint(x: 175, y: 202.5), is: AnnotationStyle.colors[green])
        check("pen: stroke is yellow", at: NSPoint(x: 100, y: 170), is: AnnotationStyle.colors[yellow])
        checkUnchanged("untouched corner", at: NSPoint(x: 10, y: 10))

        // Text: enough black pixels where the label was placed.
        var inked = 0
        for x in stride(from: 230.0, to: 390.0, by: 1) {
            for y in stride(from: 262.0, to: 296.0, by: 1) where close(pixel(out, at: NSPoint(x: x, y: y)), (0, 0, 0)) {
                inked += 1
            }
        }
        r.step("text: label is drawn", ok: inked > 150, ["blackPixels": "\(inked)"])

        // Mosaic: the stripes are gone (grey, neither black nor white) and
        // each block is one flat colour.
        let a = pixel(out, at: NSPoint(x: 53, y: 53)), b = pixel(out, at: NSPoint(x: 57, y: 57))
        r.step("mosaic: stripes blurred to grey", ok: a.0 > 0.2 && a.0 < 0.8, ["got": describe(a)])
        r.step("mosaic: a block is one flat colour", ok: close(a, b, tolerance: 0.01), ["p1": describe(a), "p2": describe(b)])
        checkUnchanged("mosaic: stops at its edge", at: NSPoint(x: 210, y: 90))

        // ── Undo / redo ──
        canvas.undo()
        r.expect("undo: removes the last mark", document.annotations.count, 5)
        if let undone = document.renderPNG().flatMap(NSBitmapImageRep.init(data:)) {
            let p = NSPoint(x: 53, y: 53)
            r.step("undo: pixels return to the original", ok: close(pixel(undone, at: p), pixel(baseRep, at: p)))
        }
        r.expect("undo: redo becomes available", document.canRedo, true)
        canvas.redo()
        r.expect("redo: restores the mark", document.annotations.count, 6)
        drag(.pen, color: red, [NSPoint(x: 5, y: 5)])
        r.expect("pen: a single click leaves a dot", document.annotations.count, 7)
        r.expect("new mark clears the redo stack", document.canRedo, false)
        canvas.undo()

        // ── A canvas shown smaller than the image maps the pointer back ──
        let small = AnnotationCanvasView(document: document)
        small.frame = NSRect(x: 0, y: 0, width: 200, height: 150)
        small.tool = .rectangle
        small.begin(at: NSPoint(x: 10, y: 10))
        small.end(at: NSPoint(x: 60, y: 40))
        if case .rectangle(let rect, _)? = document.annotations.last {
            r.expect("scaled canvas: pointer maps to document space", "\(rect)", "\(NSRect(x: 20, y: 20, width: 100, height: 60))")
        } else {
            r.step("scaled canvas: pointer maps to document space", ok: false)
        }
        small.undo()

        runEditorWiring(request, document, &r)
        runEditorEvents(document, &r)
        runHoverTable(&r)
        runEditorLayout(&r)

        // ── Pictures for a human to look at ──
        var written: [String] = []
        func save(_ view: NSView, as name: String) {
            if let data = render(view), (try? data.write(to: request.dir.appendingPathComponent(name))) != nil {
                written.append(name)
            }
        }
        save(canvas, as: "canvas.png")
        let toolbar = AnnotationToolbar()
        toolbar.tool = .rectangle
        toolbar.colorIndex = 3
        toolbar.widthIndex = 2
        toolbar.canUndo = true
        save(toolbar, as: "toolbar.png")
        let card = PreviewImageView()
        card.frame = NSRect(origin: .zero, size: HistoryHoverPreview.frame(
            imageSize: document.size, anchor: NSRect(x: 100, y: 100, width: 520, height: 480),
            rowMidY: 300, screen: NSRect(x: 0, y: 0, width: 1600, height: 1000)).size)
        card.image = NSImage(data: png)
        save(card, as: "hover-preview.png")
        // The region picker with its new Annotate button. Its backgrounds are
        // layer colours, which this renderer doesn't capture — the picture
        // shows icon and label placement only.
        save(CaptureActionPicker().buildContent(width: CaptureActionPicker.width, height: 66), as: "picker.png")
        r.step("renders written for review", ok: written.count == 4, ["files": written.joined(separator: ", ")])
    }

    // MARK: - Editor wiring (built, never shown)

    private static func runEditorWiring(_ request: Request, _ document: AnnotationDocument, _ r: inout Report) {
        let editor = ScreenshotEditor()
        var doneData: Data?
        var cancelled = false
        let before = document.annotations.count

        editor.open(document: document, over: NSRect(x: 200, y: 200, width: 400, height: 300), show: false,
                    onDone: { doneData = $0 }, onCancel: { cancelled = true })
        guard let canvas = editor.canvas, let toolbar = editor.toolbar else {
            r.step("editor: opens", ok: false)
            return
        }
        r.expect("editor: canvas matches the selection", "\(canvas.frame.size)", "\(NSSize(width: 400, height: 300))")

        toolbar.select(.tool(.pen))
        r.expect("toolbar → canvas: tool", canvas.tool, .pen)
        toolbar.select(.color(2))
        r.expect("toolbar → canvas: colour", canvas.style.color, AnnotationStyle.colors[2])
        toolbar.select(.width(2))
        r.expect("toolbar → canvas: thickness", canvas.style.lineWidth, AnnotationStyle.lineWidths[2])

        canvas.begin(at: NSPoint(x: 300, y: 30))
        canvas.end(at: NSPoint(x: 300, y: 30))
        r.expect("canvas → toolbar: undo lights up", toolbar.canUndo, true)
        toolbar.select(.undo)
        r.expect("toolbar undo: mark removed", document.annotations.count, before)
        r.expect("canvas → toolbar: redo lights up", toolbar.canRedo, true)
        toolbar.select(.redo)
        toolbar.select(.undo)

        toolbar.select(.done)
        let flattened = doneData.flatMap(NSBitmapImageRep.init(data:))
        r.step("editor done: hands back a full-resolution PNG",
               ok: flattened?.pixelsWide == Int(document.pixelSize.width) && !cancelled && !editor.isOpen)

        editor.open(document: document, over: NSRect(x: 200, y: 200, width: 400, height: 300), show: false,
                    onDone: { _ in doneData = nil }, onCancel: { cancelled = true })
        editor.toolbar?.select(.cancel)
        r.step("editor cancel: reports cancel, not done", ok: cancelled && doneData != nil && !editor.isOpen)
    }

    // MARK: - Through the window's own event dispatch

    /// Send a mouse event to whatever view is under `point` (given in `view`'s
    /// coordinates), the way AppKit would deliver a real one.
    static func mouse(_ type: NSEvent.EventType, in view: NSView, at point: NSPoint) {
        guard let window = view.window, let event = NSEvent.mouseEvent(
            with: type, location: view.convert(point, to: nil), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { return }
        window.sendEvent(event)
    }

    /// The same marks as before, but arriving as NSEvents through
    /// NSWindow.sendEvent — hit-testing, first-responder changes and the
    /// inline text field's editor are all real here. Still never on screen.
    private static func runEditorEvents(_ document: AnnotationDocument, _ r: inout Report) {
        let editor = ScreenshotEditor()
        // AppKit only dispatches events to windows that are ordered in, so
        // these are — far outside any display, where nobody sees them.
        let offscreen = NSRect(x: -30000, y: -30000, width: 400, height: 300)
        editor.open(document: document, over: offscreen, show: false, onDone: { _ in }, onCancel: {})
        defer { editor.cancel() }
        guard let canvas = editor.canvas, let toolbar = editor.toolbar,
              let canvasWindow = canvas.window, let toolbarWindow = toolbar.window else {
            r.step("events: editor has windows", ok: false)
            return
        }
        toolbarWindow.setFrameOrigin(NSPoint(x: offscreen.minX, y: offscreen.minY - 60))
        canvasWindow.orderFront(nil)
        toolbarWindow.orderFront(nil)
        let onAnyScreen = NSScreen.screens.contains { $0.frame.intersects(canvasWindow.frame) || $0.frame.intersects(toolbarWindow.frame) }
        r.step("events: test windows are ordered in but off every display",
               ok: canvasWindow.isVisible && toolbarWindow.isVisible && !onAnyScreen,
               ["canvas": "\(canvasWindow.frame.origin)", "toolbar": "\(toolbarWindow.frame.origin)"])
        let before = document.annotations.count
        func click(_ item: AnnotationToolbar.Item) {
            guard let rect = toolbar.rect(of: item) else { return }
            mouse(.leftMouseDown, in: toolbar, at: NSPoint(x: rect.midX, y: rect.midY))
            mouse(.leftMouseUp, in: toolbar, at: NSPoint(x: rect.midX, y: rect.midY))
        }

        click(.tool(.rectangle))
        r.expect("events: clicking a toolbar button selects the tool", canvas.tool, .rectangle)

        mouse(.leftMouseDown, in: canvas, at: NSPoint(x: 50, y: 50))
        mouse(.leftMouseDragged, in: canvas, at: NSPoint(x: 120, y: 100))
        mouse(.leftMouseUp, in: canvas, at: NSPoint(x: 150, y: 120))
        if case .rectangle(let rect, _)? = document.annotations.last, document.annotations.count == before + 1 {
            r.expect("events: dragging on the canvas draws", "\(rect)", "\(NSRect(x: 50, y: 50, width: 100, height: 70))")
        } else {
            r.step("events: dragging on the canvas draws", ok: false, ["marks": "\(document.annotations.count - before)"])
        }

        // Text: click to place the field, type into its editor, Return commits.
        click(.tool(.text))
        mouse(.leftMouseDown, in: canvas, at: NSPoint(x: 60, y: 200))
        mouse(.leftMouseUp, in: canvas, at: NSPoint(x: 60, y: 200))
        let fieldEditor = canvas.window?.firstResponder as? NSTextView
        r.step("events: clicking with the text tool focuses a text field", ok: canvas.isEditingText && fieldEditor != nil)
        fieldEditor?.insertText("Hi there", replacementRange: NSRange(location: NSNotFound, length: 0))
        fieldEditor?.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        if case .text(let string, let topLeft, _)? = document.annotations.last {
            r.expect("events: typed text is committed by Return", string, "Hi there")
            r.expect("events: the label sits where the click was", "\(topLeft)", "\(NSPoint(x: 60, y: 200))")
        } else {
            r.step("events: typed text is committed by Return", ok: false)
        }
        r.expect("events: the field is gone after committing", canvas.isEditingText, false)

        // Esc while typing discards that label only.
        let afterText = document.annotations.count
        mouse(.leftMouseDown, in: canvas, at: NSPoint(x: 60, y: 120))
        mouse(.leftMouseUp, in: canvas, at: NSPoint(x: 60, y: 120))
        let secondEditor = canvas.window?.firstResponder as? NSTextView
        secondEditor?.insertText("discard me", replacementRange: NSRange(location: NSNotFound, length: 0))
        secondEditor?.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        r.step("events: Esc while typing discards the label", ok: document.annotations.count == afterText && !canvas.isEditingText)

        // Switching tool mid-typing keeps what was typed.
        mouse(.leftMouseDown, in: canvas, at: NSPoint(x: 200, y: 120))
        mouse(.leftMouseUp, in: canvas, at: NSPoint(x: 200, y: 120))
        (canvas.window?.firstResponder as? NSTextView)?.insertText("kept", replacementRange: NSRange(location: NSNotFound, length: 0))
        click(.tool(.arrow))
        if case .text(let string, _, _)? = document.annotations.last {
            r.expect("events: switching tools commits the label being typed", string, "kept")
        } else {
            r.step("events: switching tools commits the label being typed", ok: false)
        }

        click(.undo); click(.undo); click(.undo)
        r.expect("events: toolbar undo button", document.annotations.count, before)
    }

    // MARK: - Hover-aware table

    private final class EightRows: NSObject, NSTableViewDataSource {
        func numberOfRows(in tableView: NSTableView) -> Int { 8 }
    }

    private static func runHoverTable(_ r: inout Report) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 220), styleMask: .borderless,
                              backing: .buffered, defer: true)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 220))
        let table = HoverTableView(frame: scroll.bounds)
        let rows = EightRows()
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c")))
        table.headerView = nil
        table.rowHeight = 50
        table.intercellSpacing = .zero
        table.dataSource = rows
        scroll.documentView = table
        window.contentView = scroll
        table.reloadData()
        window.contentView?.layoutSubtreeIfNeeded()

        var reported: [String] = []
        table.onHoverRow = { reported.append($0.map(String.init) ?? "none") }
        func move(toRow row: Int, offset: CGFloat = 25) {
            let point = NSPoint(x: 20, y: CGFloat(row) * 50 + offset)   // the table is flipped: y grows downward
            guard let event = NSEvent.mouseEvent(
                with: .mouseMoved, location: table.convert(point, to: nil), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 0, pressure: 0) else { return }
            table.mouseMoved(with: event)
        }
        move(toRow: 1)
        move(toRow: 1, offset: 40)     // still row 1: no second report
        move(toRow: 2)
        r.expect("hover table: reports each row once as the pointer crosses it", reported, ["1", "2"])
        if let exit = NSEvent.enterExitEvent(with: .mouseExited, location: .zero, modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                             context: nil, eventNumber: 0, trackingNumber: 0, userData: nil) {
            table.mouseExited(with: exit)
        }
        r.expect("hover table: reports leaving", reported.last, "none")
        withExtendedLifetime(rows) {}
    }

    // MARK: - Layout rules

    private static func runEditorLayout(_ r: inout Report) {
        let screen = NSRect(x: 0, y: 0, width: 1600, height: 1000)
        let bar = NSSize(width: 480, height: 40)
        func origin(_ selection: NSRect) -> String {
            "\(ScreenshotEditor.toolbarOrigin(for: selection, toolbarSize: bar, screen: screen))"
        }
        r.expect("toolbar: below the selection, right-aligned",
                 origin(NSRect(x: 400, y: 400, width: 600, height: 300)), "\(NSPoint(x: 520, y: 352))")
        r.expect("toolbar: above when there's no room below",
                 origin(NSRect(x: 400, y: 20, width: 600, height: 300)), "\(NSPoint(x: 520, y: 328))")
        r.expect("toolbar: inside when the selection fills the screen",
                 origin(NSRect(x: 0, y: 0, width: 1600, height: 1000)), "\(NSPoint(x: 1112, y: 8))")
        r.expect("toolbar: kept on screen for a narrow selection at the left edge",
                 origin(NSRect(x: 0, y: 400, width: 100, height: 300)), "\(NSPoint(x: 8, y: 352))")

        // The region picker (Capture / Annotate / Record).
        let picker = NSSize(width: CaptureActionPicker.width, height: 66)
        func pickerOrigin(_ selection: NSRect, on screen: NSRect = screen) -> String {
            "\(CaptureActionPicker.origin(near: selection, size: picker, screen: screen))"
        }
        r.expect("picker: below the selection, centred",
                 pickerOrigin(NSRect(x: 400, y: 400, width: 600, height: 300)), "\(NSPoint(x: 539, y: 322))")
        r.expect("picker: above when there's no room below",
                 pickerOrigin(NSRect(x: 400, y: 20, width: 600, height: 300)), "\(NSPoint(x: 539, y: 332))")
        r.expect("picker: on screen when the selection fills it",
                 pickerOrigin(NSRect(x: 0, y: 0, width: 1600, height: 1000)), "\(NSPoint(x: 639, y: 926))")
        r.expect("picker: stays on the second display the selection is on",
                 pickerOrigin(NSRect(x: 2000, y: 400, width: 400, height: 300),
                              on: NSRect(x: 1600, y: 0, width: 1600, height: 1000)), "\(NSPoint(x: 2039, y: 322))")

        let anchor = NSRect(x: 300, y: 260, width: 520, height: 480)
        func preview(_ image: NSSize, anchor: NSRect = anchor, rowMidY: CGFloat = 500) -> NSRect {
            HistoryHoverPreview.frame(imageSize: image, anchor: anchor, rowMidY: rowMidY, screen: screen)
        }
        let big = preview(NSSize(width: 1600, height: 1000))
        r.expect("preview: to the right of the panel", big.minX, anchor.maxX + HistoryHoverPreview.gap)
        r.expect("preview: large image scaled to fit, aspect kept", "\(big.size)", "\(NSSize(width: 496, height: 316))")
        r.expect("preview: centred on the hovered row", big.midY, 500)
        r.expect("preview: small image isn't enlarged", "\(preview(NSSize(width: 120, height: 80)).size)",
                 "\(NSSize(width: 136, height: 96))")
        let nearRight = NSRect(x: 1060, y: 260, width: 520, height: 480)
        r.expect("preview: flips left when the right side is off screen",
                 preview(NSSize(width: 1600, height: 1000), anchor: nearRight).maxX, nearRight.minX - HistoryHoverPreview.gap)
        r.expect("preview: kept on screen for a row near the top",
                 preview(NSSize(width: 800, height: 1200), rowMidY: 990).maxY, screen.maxY - 8)
    }

    // MARK: - Helpers

    /// A light page with a block of 2-pt black/white stripes.
    private static func makeBaseImage() -> Data? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(basePointSize.width) * baseScale,
            pixelsHigh: Int(basePointSize.height) * baseScale, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = basePointSize
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor(deviceWhite: 0.92, alpha: 1).setFill()
        NSRect(origin: .zero, size: basePointSize).fill()
        var x = stripes.minX
        var dark = true
        while x < stripes.maxX {
            (dark ? NSColor.black : NSColor.white).setFill()
            NSRect(x: x, y: stripes.minY, width: 2, height: stripes.height).fill()
            x += 2
            dark.toggle()
        }
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    private typealias RGB = (Double, Double, Double)

    /// Colour of the pixel under a document point (origin bottom-left).
    private static func pixel(_ rep: NSBitmapImageRep, at p: NSPoint) -> RGB {
        let sx = CGFloat(rep.pixelsWide) / basePointSize.width, sy = CGFloat(rep.pixelsHigh) / basePointSize.height
        let x = min(max(Int(p.x * sx), 0), rep.pixelsWide - 1)
        let y = min(max(Int((basePointSize.height - p.y) * sy), 0), rep.pixelsHigh - 1)
        guard let c = rep.colorAt(x: x, y: y) else { return (-1, -1, -1) }
        return (Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
    }

    private static func rgb(_ color: NSColor) -> RGB {
        let c = color.usingColorSpace(.deviceRGB) ?? color
        return (Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
    }

    private static func close(_ a: RGB, _ b: RGB, tolerance: Double = 0.08) -> Bool {
        abs(a.0 - b.0) <= tolerance && abs(a.1 - b.1) <= tolerance && abs(a.2 - b.2) <= tolerance
    }

    private static func describe(_ c: RGB) -> String {
        String(format: "(%.2f, %.2f, %.2f)", c.0, c.1, c.2)
    }

    /// Draw a view and its subviews into a 2× bitmap by calling `draw(_:)` —
    /// works for the self-drawn views here whether or not they are in a
    /// window. Layer-only styling (background colours, corner radii) is not
    /// captured.
    static func render(_ view: NSView) -> Data? {
        let size = view.bounds.size
        guard size.width > 0, size.height > 0, let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width) * 2, pixelsHigh: Int(size.height) * 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = size
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor(white: 0.12, alpha: 1).setFill()   // stand-in for the dark panel behind
        view.bounds.fill()
        drawTree(view)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    private static func drawTree(_ view: NSView) {
        view.draw(view.bounds)
        for sub in view.subviews where !sub.isHidden {
            NSGraphicsContext.saveGraphicsState()
            let move = NSAffineTransform()
            move.translateX(by: sub.frame.minX, yBy: sub.frame.minY)
            move.concat()
            drawTree(sub)
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}
