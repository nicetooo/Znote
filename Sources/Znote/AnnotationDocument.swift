import AppKit

// MARK: - Model

enum AnnotationTool: String, CaseIterable {
    case pen, arrow, rectangle, ellipse, text, mosaic
}

struct AnnotationStyle: Equatable {
    var color: NSColor
    /// Stroke width in points. The text tool derives its font size from it.
    var lineWidth: CGFloat

    var fontSize: CGFloat { 10 + lineWidth * 4 }

    static let colors: [NSColor] = [
        NSColor(srgbRed: 1.00, green: 0.23, blue: 0.19, alpha: 1),  // red
        NSColor(srgbRed: 1.00, green: 0.80, blue: 0.00, alpha: 1),  // yellow
        NSColor(srgbRed: 0.20, green: 0.78, blue: 0.35, alpha: 1),  // green
        NSColor(srgbRed: 0.04, green: 0.52, blue: 1.00, alpha: 1),  // blue
        NSColor(srgbRed: 1.00, green: 1.00, blue: 1.00, alpha: 1),  // white
        NSColor(srgbRed: 0.00, green: 0.00, blue: 0.00, alpha: 1),  // black
    ]
    static let lineWidths: [CGFloat] = [2, 4, 6]
    static let initial = AnnotationStyle(color: colors[0], lineWidth: lineWidths[1])
}

/// One mark on the screenshot. Coordinates are in points, origin bottom-left,
/// in a space the size of the screenshot (`AnnotationDocument.size`).
enum Annotation {
    case stroke(points: [NSPoint], style: AnnotationStyle)
    case arrow(from: NSPoint, to: NSPoint, style: AnnotationStyle)
    case rectangle(NSRect, style: AnnotationStyle)
    case ellipse(NSRect, style: AnnotationStyle)
    /// `topLeft` is where the first line's top-left corner sits.
    case text(String, topLeft: NSPoint, style: AnnotationStyle)
    case mosaic(NSRect)
}

// MARK: - Document

/// A screenshot plus the annotations drawn on it: the model, undo/redo,
/// drawing, and flattening to PNG. Has no view or window of its own.
final class AnnotationDocument {
    let image: NSImage
    /// Size in points — the size the screenshot had on screen.
    let size: NSSize
    /// Size in pixels of the underlying bitmap (2× `size` on a Retina display).
    let pixelSize: NSSize

    private(set) var annotations: [Annotation] = []
    private var undone: [Annotation] = []

    /// The whole screenshot shrunk to one pixel per mosaic block — made once,
    /// reused by every mosaic rect.
    private lazy var pixellated: NSImage? = makePixellated()

    init?(image: NSImage) {
        guard let rep = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first
                ?? image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)),
              rep.pixelsWide > 0, rep.pixelsHigh > 0, image.size.width > 0, image.size.height > 0 else { return nil }
        self.image = image
        self.size = image.size
        self.pixelSize = NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
    }

    convenience init?(contentsOf url: URL) {
        guard let image = NSImage(contentsOf: url) else { return nil }
        self.init(image: image)
    }

    // MARK: Editing

    var canUndo: Bool { !annotations.isEmpty }
    var canRedo: Bool { !undone.isEmpty }

    func add(_ annotation: Annotation) {
        annotations.append(annotation)
        undone.removeAll()
    }

    func undo() {
        guard let last = annotations.popLast() else { return }
        undone.append(last)
    }

    func redo() {
        guard let next = undone.popLast() else { return }
        annotations.append(next)
    }

    // MARK: Drawing

    /// Draw the screenshot and every annotation into the current graphics
    /// context, in a coordinate space `size` points large. `inProgress` is a
    /// mark still being dragged out.
    func draw(inProgress: Annotation? = nil) {
        let bounds = NSRect(origin: .zero, size: size)
        image.draw(in: bounds, from: .zero, operation: .copy, fraction: 1)
        for annotation in annotations { draw(annotation) }
        if let inProgress { draw(inProgress) }
    }

    private func draw(_ annotation: Annotation) {
        switch annotation {
        case .stroke(let points, let style):
            guard let first = points.first else { return }
            let path = NSBezierPath()
            path.lineWidth = style.lineWidth
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.move(to: first)
            if points.count == 1 {
                path.line(to: first)   // a dot
            } else {
                for p in points.dropFirst() { path.line(to: p) }
            }
            style.color.setStroke()
            path.stroke()

        case .arrow(let from, let to, let style):
            let length = hypot(to.x - from.x, to.y - from.y)
            guard length > 0 else { return }
            let head = min(max(12, style.lineWidth * 4.5), length)
            let angle = atan2(to.y - from.y, to.x - from.x)
            // Stop the shaft inside the head so its round cap doesn't poke through the tip.
            let shaftEnd = NSPoint(x: to.x - cos(angle) * head * 0.7, y: to.y - sin(angle) * head * 0.7)
            let shaft = NSBezierPath()
            shaft.lineWidth = style.lineWidth
            shaft.lineCapStyle = .round
            shaft.move(to: from)
            shaft.line(to: shaftEnd)
            style.color.setStroke()
            shaft.stroke()

            let spread = CGFloat.pi / 7
            let tip = NSBezierPath()
            tip.move(to: to)
            tip.line(to: NSPoint(x: to.x - cos(angle - spread) * head, y: to.y - sin(angle - spread) * head))
            tip.line(to: NSPoint(x: to.x - cos(angle + spread) * head, y: to.y - sin(angle + spread) * head))
            tip.close()
            style.color.setFill()
            tip.fill()

        case .rectangle(let rect, let style):
            let path = NSBezierPath(rect: rect)
            path.lineWidth = style.lineWidth
            path.lineJoinStyle = .round
            style.color.setStroke()
            path.stroke()

        case .ellipse(let rect, let style):
            let path = NSBezierPath(ovalIn: rect)
            path.lineWidth = style.lineWidth
            style.color.setStroke()
            path.stroke()

        case .text(let string, let topLeft, let style):
            let text = NSAttributedString(string: string, attributes: AnnotationDocument.textAttributes(style))
            let height = text.size().height
            text.draw(at: NSPoint(x: topLeft.x, y: topLeft.y - height))

        case .mosaic(let rect):
            guard let pixellated else { return }
            let block = AnnotationDocument.mosaicBlock
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: rect).addClip()
            // Blown back up without smoothing, each pixel becomes one flat block.
            NSGraphicsContext.current?.imageInterpolation = .none
            pixellated.draw(in: NSRect(x: 0, y: 0, width: pixellated.size.width * block,
                                       height: pixellated.size.height * block),
                            from: .zero, operation: .copy, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    static func textAttributes(_ style: AnnotationStyle) -> [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: style.fontSize, weight: .semibold), .foregroundColor: style.color]
    }

    /// Mosaic block edge, in points.
    static let mosaicBlock: CGFloat = 10

    /// Shrink the screenshot so each mosaic block is a single pixel holding
    /// the block's average colour. (CIPixellate was tried first: it samples one
    /// pixel per block instead of averaging, so fine text came out as
    /// black-and-white speckle rather than a blur.)
    private func makePixellated() -> NSImage? {
        let block = AnnotationDocument.mosaicBlock
        let columns = Int(ceil(size.width / block)), rows = Int(ceil(size.height / block))
        guard columns > 0, rows > 0, let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: columns, pixelsHigh: rows, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        rep.size = NSSize(width: columns, height: rows)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high   // averages when scaling down
        image.draw(in: NSRect(x: 0, y: 0, width: size.width / block, height: size.height / block),
                   from: .zero, operation: .copy, fraction: 1)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        let small = NSImage(size: rep.size)
        small.addRepresentation(rep)
        return small
    }

    // MARK: Export

    /// Flatten to PNG at the screenshot's own pixel resolution.
    func renderPNG() -> Data? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(pixelSize.width), pixelsHigh: Int(pixelSize.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        // Point size on a larger pixel grid: the context scales drawing for us
        // and the PNG keeps the screenshot's DPI.
        rep.size = size
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        draw()
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}
