import AppKit

// MARK: - Hover-aware table

/// NSTableView that reports which row the pointer is over.
final class HoverTableView: NSTableView {
    /// Called when the hovered row changes; nil when the pointer is over no row.
    var onHoverRow: ((Int?) -> Void)?

    private var hoverArea: NSTrackingArea?
    private var hoveredRow: Int?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let old = hoverArea { removeTrackingArea(old) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.activeAlways, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        // Scrolling moves rows under a pointer that isn't moving.
        NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: nil)
        if let clip = superview as? NSClipView {
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(clipBoundsChanged),
                                                   name: NSView.boundsDidChangeNotification, object: clip)
        }
    }

    @objc private func clipBoundsChanged() { refreshHover() }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        update(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        update(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        setHovered(nil)
    }

    /// Re-read the pointer position — after a scroll or a reload, when rows
    /// changed without the pointer moving. Always reports, even if the row
    /// index is the same, because the row's content may not be.
    func refreshHover() {
        hoveredRow = nil
        guard let window else { onHoverRow?(nil); return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        if visibleRect.contains(point) {
            update(at: point, force: true)
        } else {
            onHoverRow?(nil)
        }
    }

    private func update(at point: NSPoint, force: Bool = false) {
        let row = self.row(at: point)
        setHovered(row >= 0 ? row : nil, force: force)
    }

    private func setHovered(_ row: Int?, force: Bool = false) {
        guard force || row != hoveredRow else { return }
        hoveredRow = row
        onHoverRow?(row)
    }
}

// MARK: - Preview panel

/// The floating image preview shown beside the History panel while the
/// pointer rests on a screenshot row.
final class HistoryHoverPreview {
    private var panel: NSPanel?
    private var imageView: PreviewImageView?
    private var shownPath: String?
    private let cache = NSCache<NSString, NSImage>()

    static let maxImageSize = NSSize(width: 480, height: 400)
    static let padding: CGFloat = 8
    static let gap: CGFloat = 10

    init() { cache.countLimit = 12 }

    /// Show the image at `path` beside `anchor`, level with the hovered row.
    func show(imagePath path: String, beside anchor: NSWindow, rowRectOnScreen: NSRect) {
        guard let image = image(at: path), image.size.width > 0, image.size.height > 0 else {
            hide()
            return
        }
        let screen = anchor.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? anchor.frame
        let frame = HistoryHoverPreview.frame(imageSize: image.size, anchor: anchor.frame,
                                              rowMidY: rowRectOnScreen.midY, screen: screen)

        let panel = self.panel ?? makePanel()
        self.panel = panel
        imageView?.image = image
        panel.setFrame(frame, display: true)
        if panel.parent !== anchor {
            panel.parent?.removeChildWindow(panel)
            anchor.addChildWindow(panel, ordered: .above)   // follows the History panel when dragged
        }
        panel.orderFront(nil)
        shownPath = path
    }

    func hide() {
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        shownPath = nil
    }

    /// Forget a file that was deleted or replaced.
    func invalidate(path: String) { cache.removeObject(forKey: path as NSString) }

    /// Where the preview goes: to the right of the History panel, vertically
    /// centred on the hovered row; on the left if the right side has no room.
    /// Images are scaled down to fit `maxImageSize`, never up.
    static func frame(imageSize: NSSize, anchor: NSRect, rowMidY: CGFloat, screen: NSRect) -> NSRect {
        let margin: CGFloat = 8
        let fit = min(1, maxImageSize.width / imageSize.width, maxImageSize.height / imageSize.height)
        let size = NSSize(width: (imageSize.width * fit).rounded() + padding * 2,
                          height: (imageSize.height * fit).rounded() + padding * 2)

        var x = anchor.maxX + gap
        if x + size.width > screen.maxX - margin {
            let left = anchor.minX - gap - size.width
            // Neither side fits: stay right and let the screen edge clamp it.
            x = left >= screen.minX + margin ? left : max(screen.minX + margin, screen.maxX - margin - size.width)
        }
        let y = min(max(rowMidY - size.height / 2, screen.minY + margin),
                    max(screen.minY + margin, screen.maxY - margin - size.height))
        return NSRect(origin: NSPoint(x: x, y: y), size: size)
    }

    private func image(at path: String) -> NSImage? {
        if let cached = cache.object(forKey: path as NSString) { return cached }
        guard let image = NSImage(contentsOfFile: path) else { return nil }
        cache.setObject(image, forKey: path as NSString)
        return image
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.hasShadow = true
        panel.ignoresMouseEvents = true   // never steals the hover it depends on
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let view = PreviewImageView()
        panel.contentView = view
        imageView = view
        return panel
    }
}

/// Dark rounded card with the image inset by `HistoryHoverPreview.padding`.
final class PreviewImageView: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let card = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)
        NSColor(white: 0.10, alpha: 0.97).setFill()
        card.fill()
        NSColor(white: 1, alpha: 0.14).setStroke()
        card.lineWidth = 1
        card.stroke()

        guard let image else { return }
        let inset = bounds.insetBy(dx: HistoryHoverPreview.padding, dy: HistoryHoverPreview.padding)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: inset, xRadius: 6, yRadius: 6).addClip()
        image.draw(in: inset, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
    }
}
