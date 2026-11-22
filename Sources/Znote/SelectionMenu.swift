import AppKit

/// The small horizontal menu shown beside the pointer after the selection
/// hotkey: Translate · Note · ✕.
///
/// It never takes keyboard focus — the app the text was selected in stays in
/// charge, selection and all. Click a button, or tap the hotkey again for the
/// default (Translate). A click anywhere else, or any key, dismisses it.
final class SelectionMenu {
    enum Choice: Equatable { case translate, note }

    static let height: CGFloat = 44

    /// Just right of and below the pointer; above it when there's no room
    /// below; always fully inside `screen`. Shared with the note panel.
    static func origin(nearPointer pointer: NSPoint, size: NSSize, screen: NSRect) -> NSPoint {
        let gap: CGFloat = 12, margin: CGFloat = 8
        var y = pointer.y - size.height - gap
        if y < screen.minY + margin { y = pointer.y + gap }
        y = min(max(y, screen.minY + margin), screen.maxY - margin - size.height)
        let x = min(max(pointer.x + gap, screen.minX + margin), screen.maxX - margin - size.width)
        return NSPoint(x: x, y: y)
    }

    /// The usable area of the screen `pointer` is on.
    static func screenArea(containing pointer: NSPoint) -> NSRect {
        let screen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main
        return screen?.visibleFrame ?? NSRect(origin: pointer, size: .zero)
    }

    private var panel: NSPanel?
    private var monitors: [Any] = []
    private var onChoose: ((Choice) -> Void)?
    private var onDismiss: (() -> Void)?

    // Exposed for the self-test.
    private(set) var translateButton: PickerButton?
    private(set) var noteButton: PickerButton?
    private(set) var closeButton: PickerButton?
    var window: NSWindow? { panel }

    var isShowing: Bool { panel != nil }

    /// - Parameter live: false for the self-test — the panel is created at
    ///   `pointer` exactly, not ordered in, and nothing outside it is watched.
    func show(near pointer: NSPoint, live: Bool = true,
              onChoose: @escaping (Choice) -> Void, onDismiss: (() -> Void)? = nil) {
        dismiss()
        self.onChoose = onChoose
        self.onDismiss = onDismiss

        let content = buildContent()
        let size = content.frame.size
        let origin = live
            ? SelectionMenu.origin(nearPointer: pointer, size: size, screen: SelectionMenu.screenArea(containing: pointer))
            : pointer

        let p = NSPanel(contentRect: NSRect(origin: origin, size: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .floating
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = content
        panel = p
        guard live else { return }

        p.orderFront(nil)
        // Clicks on the menu itself never reach a global monitor.
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown],
                                                     handler: { [weak self] _ in self?.cancel() }) {
            monitors.append(m)
        }
        log("SelectionMenu: shown at \(origin)")
    }

    /// What a second tap of the hotkey means.
    func chooseDefault() { choose(.translate) }

    func choose(_ choice: Choice) {
        guard isShowing else { return }
        let callback = onChoose
        dismiss()
        callback?(choice)
    }

    /// Dismissed without a choice.
    func cancel() {
        guard isShowing else { return }
        let callback = onDismiss
        dismiss()
        callback?()
    }

    func dismiss() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        panel?.orderOut(nil)
        panel = nil
        translateButton = nil
        noteButton = nil
        closeButton = nil
        onChoose = nil
        onDismiss = nil
    }

    // MARK: - UI

    private func buildContent() -> NSView {
        let pad: CGFloat = 6, gap: CGFloat = 4, buttonHeight: CGFloat = 32

        let translate = PickerButton(symbol: "character.bubble", title: L("selection.translate"), accent: true)
        translate.onClick = { [weak self] in self?.choose(.translate) }
        let note = PickerButton(symbol: "square.and.pencil", title: L("selection.note"))
        note.onClick = { [weak self] in self?.choose(.note) }
        let close = PickerButton(symbol: "xmark", title: nil, destructive: true)
        close.onClick = { [weak self] in self?.cancel() }

        var x = pad
        let y = (SelectionMenu.height - buttonHeight) / 2
        let buttons: [(PickerButton, CGFloat)] = [
            (translate, PickerButton.width(for: L("selection.translate"))),
            (note, PickerButton.width(for: L("selection.note"))),
            (close, 28),
        ]
        for (button, width) in buttons {
            button.frame = NSRect(x: x, y: y, width: width, height: buttonHeight)
            x += width + gap
        }

        let root = NSView(frame: NSRect(x: 0, y: 0, width: x - gap + pad, height: SelectionMenu.height))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(white: 0.10, alpha: 0.96).cgColor
        root.layer?.cornerRadius = 12
        root.layer?.borderColor = NSColor(white: 1.0, alpha: 0.12).cgColor
        root.layer?.borderWidth = 1
        root.appearance = NSAppearance(named: .darkAqua)
        [translate, note, close].forEach(root.addSubview)

        translateButton = translate
        noteButton = note
        closeButton = close
        return root
    }
}
