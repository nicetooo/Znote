import AppKit

private let editorAccent = NSColor(srgbRed: 0.20, green: 0.50, blue: 0.95, alpha: 1)

// MARK: - Canvas

/// Shows an `AnnotationDocument` and turns pointer drags into annotations.
///
/// The view may be a different size from the document (a screenshot whose
/// file carries no DPI comes in at pixel size); everything is drawn scaled to
/// fit and pointer positions are mapped back into document coordinates.
final class AnnotationCanvasView: NSView, NSTextFieldDelegate {
    let document: AnnotationDocument
    var tool: AnnotationTool = .arrow {
        didSet {
            guard tool != oldValue else { return }
            commitText()
            window?.invalidateCursorRects(for: self)
        }
    }
    var style = AnnotationStyle.initial {
        didSet {
            textField?.textColor = style.color
            textField?.font = editingFont
        }
    }
    /// Fired whenever the document changes, so the toolbar can refresh.
    var onChange: (() -> Void)?

    private var inProgress: Annotation?
    private var dragStart: NSPoint?
    private var strokePoints: [NSPoint] = []

    private var textField: NSTextField?
    private var textTopLeft = NSPoint.zero
    var isEditingText: Bool { textField != nil }

    init(document: AnnotationDocument) {
        self.document = document
        super.init(frame: NSRect(origin: .zero, size: document.size))
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var scale: CGFloat { document.size.width > 0 ? bounds.width / document.size.width : 1 }

    private func toDocument(_ viewPoint: NSPoint) -> NSPoint {
        let s = scale
        return NSPoint(x: min(max(viewPoint.x, 0), bounds.width) / s,
                       y: min(max(viewPoint.y, 0), bounds.height) / s)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.scale(by: scale)
        transform.concat()
        document.draw(inProgress: inProgress)
        NSGraphicsContext.restoreGraphicsState()

        // A frame so the editable area reads as separate from the screen
        // behind it. Drawn here, not by the document, so it never exports.
        editorAccent.setStroke()
        let frame = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
        frame.lineWidth = 1
        frame.stroke()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: tool == .text ? .iBeam : .crosshair)
    }

    // MARK: Interaction (view coordinates)
    //
    // The mouse handlers only forward here, so the same path can be driven
    // without events or a window.

    func begin(at viewPoint: NSPoint) {
        let p = toDocument(viewPoint)
        if tool == .text {
            beginText(at: p)
            return
        }
        commitText()
        dragStart = p
        strokePoints = [p]
        inProgress = annotation(from: p, to: p)
        needsDisplay = true
    }

    func drag(to viewPoint: NSPoint) {
        guard let start = dragStart else { return }
        let p = toDocument(viewPoint)
        if tool == .pen { strokePoints.append(p) }
        inProgress = annotation(from: start, to: p)
        needsDisplay = true
    }

    func end(at viewPoint: NSPoint) {
        guard let start = dragStart else { return }
        let p = toDocument(viewPoint)
        let finished = annotation(from: start, to: p)
        dragStart = nil
        inProgress = nil
        strokePoints = []
        if let finished, AnnotationCanvasView.isDeliberate(finished) {
            document.add(finished)
            onChange?()
        }
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) { begin(at: convert(event.locationInWindow, from: nil)) }
    override func mouseDragged(with event: NSEvent) { drag(to: convert(event.locationInWindow, from: nil)) }
    override func mouseUp(with event: NSEvent) { end(at: convert(event.locationInWindow, from: nil)) }

    private func annotation(from start: NSPoint, to current: NSPoint) -> Annotation? {
        let rect = NSRect(x: min(start.x, current.x), y: min(start.y, current.y),
                          width: abs(current.x - start.x), height: abs(current.y - start.y))
        switch tool {
        case .pen: return .stroke(points: strokePoints, style: style)
        case .arrow: return .arrow(from: start, to: current, style: style)
        case .rectangle: return .rectangle(rect, style: style)
        case .ellipse: return .ellipse(rect, style: style)
        case .mosaic: return .mosaic(rect)
        case .text: return nil
        }
    }

    /// A stray click shouldn't leave a speck behind — except with the pen,
    /// where a dot is a legitimate mark.
    private static func isDeliberate(_ annotation: Annotation) -> Bool {
        switch annotation {
        case .stroke: return true
        case .arrow(let from, let to, _): return hypot(to.x - from.x, to.y - from.y) >= 4
        case .rectangle(let r, _), .ellipse(let r, _), .mosaic(let r): return r.width >= 3 && r.height >= 3
        case .text(let s, _, _): return !s.isEmpty
        }
    }

    func undo() { commitText(); document.undo(); onChange?(); needsDisplay = true }
    func redo() { commitText(); document.redo(); onChange?(); needsDisplay = true }

    // MARK: Text

    private var editingFont: NSFont { .systemFont(ofSize: style.fontSize * scale, weight: .semibold) }

    /// NSTextField draws its text this far in from its left edge.
    private static let fieldTextInset: CGFloat = 2

    private func beginText(at point: NSPoint) {
        commitText()
        let field = NSTextField(string: "")
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = editingFont
        field.textColor = style.color
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.delegate = self
        // Outline the box: an empty transparent field would be invisible.
        field.wantsLayer = true
        field.layer?.borderWidth = 1
        field.layer?.borderColor = editorAccent.withAlphaComponent(0.8).cgColor

        let height = ceil(field.fittingSize.height)
        let x = point.x * scale, top = point.y * scale
        let width = max(80, bounds.width - x)
        field.frame = NSRect(x: x - AnnotationCanvasView.fieldTextInset, y: top - height, width: width, height: height)
        addSubview(field)
        window?.makeFirstResponder(field)
        textField = field
        textTopLeft = point
    }

    /// Place a text annotation directly (what finishing the inline field does).
    func addText(_ string: String, at viewPoint: NSPoint) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        document.add(.text(trimmed, topLeft: toDocument(viewPoint), style: style))
        onChange?()
        needsDisplay = true
    }

    func commitText() {
        guard let field = textField else { return }
        textField = nil   // first: removing the field ends editing, which calls back here
        let string = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        field.removeFromSuperview()
        if !string.isEmpty {
            document.add(.text(string, topLeft: textTopLeft, style: style))
            onChange?()
        }
        needsDisplay = true
        window?.makeFirstResponder(self)
    }

    func cancelText() {
        guard let field = textField else { return }
        textField = nil
        field.removeFromSuperview()
        needsDisplay = true
        window?.makeFirstResponder(self)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) { commitText(); return true }
        if selector == #selector(NSResponder.cancelOperation(_:)) { cancelText(); return true }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) { commitText() }
}

// MARK: - Toolbar

/// The strip of tools, colors, widths and actions under the canvas. One view
/// that draws and hit-tests all of its items itself.
final class AnnotationToolbar: NSView, NSViewToolTipOwner {
    enum Item: Equatable {
        case tool(AnnotationTool)
        case color(Int)
        case width(Int)
        case undo, redo, cancel, done
    }

    var onSelect: ((Item) -> Void)?

    var tool: AnnotationTool = .arrow { didSet { needsDisplay = true } }
    var colorIndex = 0 { didSet { needsDisplay = true } }
    var widthIndex = 1 { didSet { needsDisplay = true } }
    var canUndo = false { didSet { needsDisplay = true } }
    var canRedo = false { didSet { needsDisplay = true } }

    private let items: [(item: Item, rect: NSRect)]
    private var hovered: Int?
    private var trackingArea: NSTrackingArea?

    static let barHeight: CGFloat = 40

    init() {
        var laidOut: [(Item, NSRect)] = []
        var x: CGFloat = 8
        let y: CGFloat = 6, h: CGFloat = AnnotationToolbar.barHeight - 12
        func place(_ item: Item, width: CGFloat, gapAfter: CGFloat) {
            laidOut.append((item, NSRect(x: x, y: y, width: width, height: h)))
            x += width + gapAfter
        }
        let tools = AnnotationTool.allCases
        for (i, t) in tools.enumerated() { place(.tool(t), width: 30, gapAfter: i == tools.count - 1 ? 12 : 2) }
        let colors = AnnotationStyle.colors.count
        for i in 0..<colors { place(.color(i), width: 20, gapAfter: i == colors - 1 ? 12 : 2) }
        let widths = AnnotationStyle.lineWidths.count
        for i in 0..<widths { place(.width(i), width: 24, gapAfter: i == widths - 1 ? 12 : 2) }
        place(.undo, width: 28, gapAfter: 2)
        place(.redo, width: 28, gapAfter: 12)
        place(.cancel, width: 28, gapAfter: 4)
        place(.done, width: 40, gapAfter: 8)
        items = laidOut.map { (item: $0.0, rect: $0.1) }
        super.init(frame: NSRect(x: 0, y: 0, width: x, height: AnnotationToolbar.barHeight))

        for (index, entry) in items.enumerated() {
            addToolTip(entry.rect, owner: self, userData: UnsafeMutableRawPointer(bitPattern: index + 1))
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Labels

    private static func symbol(for item: Item) -> String? {
        switch item {
        case .tool(.pen): return "scribble"
        case .tool(.arrow): return "arrow.up.right"
        case .tool(.rectangle): return "rectangle"
        case .tool(.ellipse): return "circle"
        case .tool(.text): return nil   // drawn as a letter: the "textformat" symbol is localized ("格式" in Chinese)
        case .tool(.mosaic): return "checkerboard.rectangle"
        case .undo: return "arrow.uturn.backward"
        case .redo: return "arrow.uturn.forward"
        case .cancel: return "xmark"
        case .done: return "checkmark"
        case .color, .width: return nil
        }
    }

    static func shortcut(for tool: AnnotationTool) -> String {
        switch tool {
        case .pen: return "P"
        case .arrow: return "A"
        case .rectangle: return "R"
        case .ellipse: return "O"
        case .text: return "T"
        case .mosaic: return "M"
        }
    }

    private static func title(for item: Item) -> String {
        switch item {
        case .tool(let t): return "\(L("editor.tool.\(t.rawValue)")) (\(shortcut(for: t)))"
        case .color: return L("editor.color")
        case .width: return L("editor.width")
        case .undo: return "\(L("editor.undo")) (⌘Z)"
        case .redo: return "\(L("editor.redo")) (⇧⌘Z)"
        case .cancel: return "\(L("editor.cancel")) (esc)"
        case .done: return "\(L("editor.done")) (↵)"
        }
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint,
                    userData data: UnsafeMutableRawPointer?) -> String {
        let index = (data.map { Int(bitPattern: $0) } ?? 0) - 1
        return items.indices.contains(index) ? AnnotationToolbar.title(for: items[index].item) : ""
    }

    // MARK: Drawing

    private func isEnabled(_ item: Item) -> Bool {
        switch item {
        case .undo: return canUndo
        case .redo: return canRedo
        default: return true
        }
    }

    private func isSelected(_ item: Item) -> Bool {
        switch item {
        case .tool(let t): return t == tool
        case .color(let i): return i == colorIndex
        case .width(let i): return i == widthIndex
        default: return false
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let background = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        NSColor(white: 0.10, alpha: 0.97).setFill()
        background.fill()
        NSColor(white: 1, alpha: 0.14).setStroke()
        background.lineWidth = 1
        background.stroke()

        for (index, entry) in items.enumerated() {
            let item = entry.item, rect = entry.rect
            let enabled = isEnabled(item), selected = isSelected(item)
            let pill = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)

            switch item {
            case .color(let i):
                let dot = NSRect(x: rect.midX - 7, y: rect.midY - 7, width: 14, height: 14)
                if selected {
                    NSColor.white.setStroke()
                    let ring = NSBezierPath(ovalIn: dot.insetBy(dx: -3, dy: -3))
                    ring.lineWidth = 1.5
                    ring.stroke()
                } else if hovered == index {
                    NSColor(white: 1, alpha: 0.12).setFill()
                    pill.fill()
                }
                AnnotationStyle.colors[i].setFill()
                NSBezierPath(ovalIn: dot).fill()
                NSColor(white: 1, alpha: 0.35).setStroke()   // keeps black and white visible
                let edge = NSBezierPath(ovalIn: dot.insetBy(dx: 0.5, dy: 0.5))
                edge.lineWidth = 1
                edge.stroke()

            case .width(let i):
                if selected {
                    NSColor(white: 1, alpha: 0.22).setFill()
                    pill.fill()
                } else if hovered == index {
                    NSColor(white: 1, alpha: 0.12).setFill()
                    pill.fill()
                }
                let d = AnnotationStyle.lineWidths[i] + 3
                NSColor.white.setFill()
                NSBezierPath(ovalIn: NSRect(x: rect.midX - d / 2, y: rect.midY - d / 2, width: d, height: d)).fill()

            default:
                var tint = NSColor.white
                if item == .done {
                    editorAccent.withAlphaComponent(hovered == index ? 1 : 0.9).setFill()
                    pill.fill()
                } else if selected {
                    editorAccent.setFill()
                    pill.fill()
                } else if hovered == index && enabled {
                    NSColor(white: 1, alpha: 0.14).setFill()
                    pill.fill()
                }
                if item == .cancel { tint = NSColor(srgbRed: 1, green: 0.45, blue: 0.42, alpha: 1) }
                if !enabled { tint = NSColor(white: 1, alpha: 0.28) }
                if item == .tool(.text) {
                    let glyph = NSAttributedString(string: "T", attributes: [
                        .font: NSFont.systemFont(ofSize: 16, weight: .semibold), .foregroundColor: tint,
                    ])
                    let size = glyph.size()
                    glyph.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
                } else {
                    drawSymbol(AnnotationToolbar.symbol(for: item), in: rect, tint: tint)
                }
            }
        }
    }

    private func drawSymbol(_ name: String?, in rect: NSRect, tint: NSColor) {
        guard let name, let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return }
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [tint]))
        let image = base.withSymbolConfiguration(config) ?? base
        let size = image.size
        image.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                              width: size.width, height: size.height))
    }

    // MARK: Pointer

    private func index(at point: NSPoint) -> Int? {
        items.firstIndex { $0.rect.insetBy(dx: -1, dy: -4).contains(point) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let old = trackingArea { removeTrackingArea(old) }
        let area = NSTrackingArea(rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        let now = index(at: convert(event.locationInWindow, from: nil))
        if now != hovered { hovered = now; needsDisplay = true }
    }

    override func mouseExited(with event: NSEvent) {
        if hovered != nil { hovered = nil; needsDisplay = true }
    }

    override func mouseDown(with event: NSEvent) {
        guard let i = index(at: convert(event.locationInWindow, from: nil)) else { return }
        select(items[i].item)
    }

    /// Act on an item as if it were clicked.
    func select(_ item: Item) {
        guard isEnabled(item) else { return }
        onSelect?(item)
    }
}

// MARK: - Editor

/// Opens a just-taken screenshot for annotation, exactly over the region it
/// was captured from, with the toolbar beside it.
final class ScreenshotEditor {
    private(set) var canvas: AnnotationCanvasView?
    private(set) var toolbar: AnnotationToolbar?
    private var canvasPanel: NSPanel?
    private var toolbarPanel: NSPanel?
    private var keyMonitor: Any?
    private var onDone: ((Data) -> Void)?
    private var onCancel: (() -> Void)?

    var isOpen: Bool { canvas != nil }

    /// - Parameters:
    ///   - rect: where the screenshot was taken, in screen coordinates.
    ///   - show: false builds everything without putting it on screen
    ///     (the self-test renders the views that way).
    func open(document: AnnotationDocument, over rect: NSRect, show: Bool = true,
              onDone: @escaping (Data) -> Void, onCancel: @escaping () -> Void) {
        guard !isOpen else { return }
        self.onDone = onDone
        self.onCancel = onCancel

        let canvas = AnnotationCanvasView(document: document)
        canvas.frame = NSRect(origin: .zero, size: rect.size)
        let toolbar = AnnotationToolbar()
        toolbar.tool = canvas.tool
        canvas.onChange = { [weak self] in self?.refreshToolbar() }
        toolbar.onSelect = { [weak self] item in self?.handle(item) }
        self.canvas = canvas
        self.toolbar = toolbar

        let canvasPanel = EditorPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel],
                                      backing: .buffered, defer: false)
        canvasPanel.level = .screenSaver
        canvasPanel.hasShadow = true
        canvasPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        canvasPanel.isMovable = false
        canvasPanel.contentView = canvas
        canvasPanel.setFrame(rect, display: false)

        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: rect.midX, y: rect.midY)) } ?? NSScreen.main
        let origin = ScreenshotEditor.toolbarOrigin(for: rect, toolbarSize: toolbar.frame.size,
                                                    screen: screen?.visibleFrame ?? rect)
        let toolbarPanel = NSPanel(contentRect: NSRect(origin: origin, size: toolbar.frame.size),
                                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        toolbarPanel.isOpaque = false
        toolbarPanel.backgroundColor = .clear
        toolbarPanel.level = .screenSaver
        toolbarPanel.hasShadow = true
        toolbarPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        toolbarPanel.contentView = toolbar
        self.canvasPanel = canvasPanel
        self.toolbarPanel = toolbarPanel
        refreshToolbar()

        guard show else { return }
        canvasPanel.addChildWindow(toolbarPanel, ordered: .above)
        canvasPanel.makeKeyAndOrderFront(nil)
        canvasPanel.makeFirstResponder(canvas)
        NSApp.activate(ignoringOtherApps: true)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleKey(event) ? nil : event
        }
        log("ScreenshotEditor: opened over \(rect), toolbar at \(origin)")
    }

    /// Where the toolbar goes: under the selection, right-aligned with it;
    /// above if there's no room below; tucked inside the bottom edge if the
    /// selection fills the screen. Always kept on screen.
    static func toolbarOrigin(for selection: NSRect, toolbarSize: NSSize, screen: NSRect) -> NSPoint {
        let gap: CGFloat = 8, margin: CGFloat = 8
        var y = selection.minY - gap - toolbarSize.height
        if y < screen.minY + margin {
            y = selection.maxY + gap
            if y + toolbarSize.height > screen.maxY - margin {
                y = selection.minY + gap
            }
        }
        y = min(max(y, screen.minY + margin), screen.maxY - margin - toolbarSize.height)
        let x = min(max(selection.maxX - toolbarSize.width, screen.minX + margin),
                    max(screen.minX + margin, screen.maxX - margin - toolbarSize.width))
        return NSPoint(x: x, y: y)
    }

    // MARK: Actions

    private func refreshToolbar() {
        guard let canvas, let toolbar else { return }
        toolbar.canUndo = canvas.document.canUndo
        toolbar.canRedo = canvas.document.canRedo
    }

    private func handle(_ item: AnnotationToolbar.Item) {
        guard let canvas, let toolbar else { return }
        switch item {
        case .tool(let t):
            canvas.tool = t
            toolbar.tool = t
        case .color(let i):
            canvas.style.color = AnnotationStyle.colors[i]
            toolbar.colorIndex = i
        case .width(let i):
            canvas.style.lineWidth = AnnotationStyle.lineWidths[i]
            toolbar.widthIndex = i
        case .undo: canvas.undo()
        case .redo: canvas.redo()
        case .cancel: cancel()
        case .done: done()
        }
    }

    /// Returns true if the key was consumed.
    private func handleKey(_ event: NSEvent) -> Bool {
        guard let canvas else { return false }
        // While typing a label the text field owns the keyboard (including
        // Return and Esc, which it turns into commit / cancel of the label).
        if canvas.isEditingText { return false }

        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if event.modifierFlags.contains(.command) {
            guard key == "z" else { return false }
            handle(event.modifierFlags.contains(.shift) ? .redo : .undo)
            return true
        }
        switch event.keyCode {
        case 53: cancel(); return true          // esc
        case 36, 76: done(); return true        // return, enter
        default: break
        }
        if let tool = AnnotationTool.allCases.first(where: { AnnotationToolbar.shortcut(for: $0).lowercased() == key }) {
            handle(.tool(tool))
            return true
        }
        return false
    }

    func done() {
        guard let canvas else { return }
        canvas.commitText()
        let data = canvas.document.renderPNG()
        let finish = onDone, abandon = onCancel
        close()
        if let data {
            finish?(data)
        } else {
            log("ScreenshotEditor: failed to render the annotated image")
            abandon?()
        }
    }

    func cancel() {
        let abandon = onCancel
        close()
        abandon?()
    }

    private func close() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        if let canvasPanel, let toolbarPanel { canvasPanel.removeChildWindow(toolbarPanel) }
        toolbarPanel?.orderOut(nil)
        canvasPanel?.orderOut(nil)
        canvasPanel = nil
        toolbarPanel = nil
        canvas = nil
        toolbar = nil
        onDone = nil
        onCancel = nil
    }
}

/// Borderless panels refuse key status by default; the canvas needs it for
/// shortcuts and for typing text labels.
private final class EditorPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
