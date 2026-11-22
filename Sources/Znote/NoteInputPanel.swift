import AppKit

/// The panel for writing a note about a selection: the selected text quoted
/// at the top, where it came from, and a few lines to type in.
///
/// It takes the keyboard (it has to) but doesn't activate Znote, so the app
/// the text was selected in stays in front. ↵ saves, ⇧↵ starts a new line,
/// esc cancels. A click outside does nothing — a stray click shouldn't cost
/// the user what they've typed.
final class NoteInputPanel: LiveTextSink {
    static let width: CGFloat = 380

    private var panel: NSPanel?
    private var onSave: ((String) -> Void)?
    private var onCancel: (() -> Void)?
    private var saveButton: PickerButton?
    private var closeTimer: Timer?

    // Exposed for the self-test.
    private(set) var textView: NoteTextView?
    private(set) var sourceLabel: NSTextField?
    var window: NSWindow? { panel }
    var content: NSView? { panel?.contentView }

    var isShowing: Bool { panel != nil }

    /// - Parameter live: false for the self-test — the panel is created at
    ///   `pointer` exactly and not ordered in.
    func show(text: String, source: SelectionSource?, near pointer: NSPoint, live: Bool = true,
              onSave: @escaping (String) -> Void, onCancel: (() -> Void)? = nil) {
        dismiss()
        self.onSave = onSave
        self.onCancel = onCancel

        let content = buildContent(text: text, source: source)
        let size = content.frame.size
        let origin = live
            ? SelectionMenu.origin(nearPointer: pointer, size: size, screen: SelectionMenu.screenArea(containing: pointer))
            : pointer

        let p = NotePanel(contentRect: NSRect(origin: origin, size: size),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .floating
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.isMovableByWindowBackground = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = content
        panel = p
        p.makeFirstResponder(textView)
        guard live else { return }

        p.makeKeyAndOrderFront(nil)
        log("NoteInputPanel: shown at \(origin)")
    }

    /// True while the note has the keyboard: what is typed — or dictated —
    /// belongs in it.
    var hasKeyboard: Bool { panel?.isKeyWindow == true && textView?.isEditable == true }

    /// Put `text` into the note at the cursor, as if it had been typed
    /// (replacing the selection, ending any input-method composition).
    /// Returns false when there is no note being written.
    @discardableResult
    func insert(_ text: String) -> Bool {
        guard isShowing, let textView, textView.isEditable else { return false }
        if textView.hasMarkedText() { textView.unmarkText() }
        textView.insertText(text, replacementRange: textView.selectedRange())
        return true
    }

    /// Live dictation: take `edit.deleted` back from just before the cursor
    /// and put `edit.inserted` there. If what should be taken back is no
    /// longer in front of the cursor — the user typed or moved meanwhile —
    /// nothing is removed.
    func apply(_ edit: LiveEdit) {
        guard isShowing, let textView, textView.isEditable else { return }
        if textView.hasMarkedText() { textView.unmarkText() }
        let caret = textView.selectedRange()
        var range = caret
        let length = (edit.deleted as NSString).length
        if length > 0, caret.length == 0, caret.location >= length {
            let before = NSRange(location: caret.location - length, length: length)
            if (textView.string as NSString).substring(with: before) == edit.deleted { range = before }
        }
        textView.insertText(edit.inserted, replacementRange: range)
    }

    /// Hand the text to `onSave`, show that it was saved, then close.
    func save() {
        guard isShowing, let onSave else { return }
        self.onSave = nil           // a second ↵ during the confirmation does nothing
        self.onCancel = nil
        onSave(textView?.string ?? "")
        saveButton?.updateTitle(L("note.saved"))
        textView?.isEditable = false
        // A timer, not the main queue: it also fires inside a nested run loop.
        closeTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in self?.dismiss() }
    }

    func cancel() {
        guard isShowing else { return }
        let callback = onCancel
        dismiss()
        callback?()
    }

    func dismiss() {
        closeTimer?.invalidate()
        closeTimer = nil
        panel?.orderOut(nil)
        panel = nil
        textView = nil
        sourceLabel = nil
        saveButton = nil
        onSave = nil
        onCancel = nil
    }

    // MARK: - UI

    private func buildContent(text: String, source: SelectionSource?) -> NSView {
        let width = NoteInputPanel.width
        let pad: CGFloat = 14
        let inner = width - pad * 2

        // Bottom row: the keys on the left, Cancel and Save on the right.
        let saveTitle = L("note.save")
        let saveWidth = max(PickerButton.width(for: saveTitle), PickerButton.width(for: L("note.saved")))
        let save = PickerButton(symbol: "checkmark", title: saveTitle, accent: true)
        save.frame = NSRect(x: width - pad - saveWidth, y: pad - 2, width: saveWidth, height: 30)
        save.onClick = { [weak self] in self?.save() }
        let close = PickerButton(symbol: "xmark", title: nil, destructive: true)
        close.frame = NSRect(x: save.frame.minX - 4 - 28, y: pad - 2, width: 28, height: 30)
        close.onClick = { [weak self] in self?.cancel() }

        let hint = NSTextField(labelWithString: L("note.hint"))
        hint.font = .systemFont(ofSize: 10, weight: .medium)
        hint.textColor = NSColor(white: 0.45, alpha: 1)
        hint.lineBreakMode = .byTruncatingTail
        hint.frame = NSRect(x: pad, y: pad + 5, width: close.frame.minX - pad - 8, height: 14)

        // The note itself.
        let editorHeight: CGFloat = 78
        let scroll = NSScrollView(frame: NSRect(x: pad, y: save.frame.maxY + 10, width: inner, height: editorHeight))
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 8
        scroll.layer?.masksToBounds = true
        scroll.layer?.backgroundColor = NSColor(white: 0.17, alpha: 1).cgColor

        let editor = NoteTextView(frame: NSRect(x: 0, y: 0, width: inner, height: editorHeight))
        editor.placeholder = L("note.placeholder")
        editor.onSubmit = { [weak self] in self?.save() }
        editor.onCancel = { [weak self] in self?.cancel() }
        scroll.documentView = editor

        // Where the selection came from — one line, absent when unknown.
        var top = scroll.frame.maxY + 8
        var views: [NSView] = [save, close, hint, scroll]
        if let label = source?.label, !label.isEmpty {
            let where_ = NSTextField(labelWithString: "↗ " + label)
            where_.font = .systemFont(ofSize: 11)
            where_.textColor = NSColor(white: 0.52, alpha: 1)
            where_.lineBreakMode = .byTruncatingMiddle
            where_.frame = NSRect(x: pad, y: top, width: inner, height: 15)
            views.append(where_)
            sourceLabel = where_
            top = where_.frame.maxY + 5
        }

        // The selection, quoted: at most two lines.
        let quoteFont = NSFont.systemFont(ofSize: 12)
        let quoted = TextFragment.collapseWhitespace(text)
        let oneLine = ceil(("Ag" as NSString).size(withAttributes: [.font: quoteFont]).height)
        let needed = (quoted as NSString).boundingRect(
            with: NSSize(width: inner - 11, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: quoteFont]).height
        let quoteHeight = needed > oneLine * 1.5 ? oneLine * 2 : oneLine

        let quote = NSTextField(wrappingLabelWithString: quoted)
        quote.font = quoteFont
        quote.textColor = NSColor(white: 0.78, alpha: 1)
        quote.isSelectable = false
        quote.maximumNumberOfLines = 2
        quote.lineBreakMode = .byTruncatingTail
        quote.cell?.truncatesLastVisibleLine = true
        quote.frame = NSRect(x: pad + 11, y: top, width: inner - 11, height: quoteHeight)

        let bar = NSView(frame: NSRect(x: pad, y: top, width: 3, height: quoteHeight))
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor(red: 0.98, green: 0.80, blue: 0.30, alpha: 1).cgColor
        bar.layer?.cornerRadius = 1.5
        views += [quote, bar]

        let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: quote.frame.maxY + pad))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(white: 0.10, alpha: 0.97).cgColor
        root.layer?.cornerRadius = 12
        root.layer?.borderColor = NSColor(white: 1.0, alpha: 0.12).cgColor
        root.layer?.borderWidth = 1
        root.appearance = NSAppearance(named: .darkAqua)
        views.forEach(root.addSubview)

        textView = editor
        saveButton = save
        return root
    }
}

/// Borderless panels refuse the keyboard unless told otherwise.
private final class NotePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// A plain-text editor for the note: ↵ submits, ⇧↵ breaks the line, esc
/// cancels — except while an input method is composing, when those keys
/// belong to it.
final class NoteTextView: NSTextView {
    var placeholder = ""
    var onSubmit: (() -> Void)?
    var onCancel: (() -> Void)?

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        configure()
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func configure() {
        isRichText = false
        allowsUndo = true
        drawsBackground = false
        font = .systemFont(ofSize: 13)
        textColor = .white
        insertionPointColor = .white
        textContainerInset = NSSize(width: 5, height: 7)
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        textContainer?.widthTracksTextView = true
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        typingAttributes = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.white]
    }

    override func keyDown(with event: NSEvent) {
        if !hasMarkedText() {
            switch event.keyCode {
            case 36, 76:        // Return, numpad Enter
                if event.modifierFlags.contains(.shift) {
                    insertNewline(nil)
                } else {
                    onSubmit?()
                }
                return
            case 53:            // esc
                onCancel?()
                return
            default:
                break
            }
        }
        super.keyDown(with: event)
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true     // the placeholder comes and goes
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !hasMarkedText() else { return }
        let origin = NSPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 5),
                             y: textContainerInset.height)
        (placeholder as NSString).draw(at: origin, withAttributes: [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor(white: 0.42, alpha: 1),
        ])
    }
}
