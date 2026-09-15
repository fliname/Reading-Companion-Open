import AppKit
import PDFKit

@MainActor
enum BookCoverRenderer {
    nonisolated static let version = 2
    private static let size = NSSize(width: 360, height: 520)

    static func pngData(imageData: Data?, title: String) -> Data? {
        render(source: imageData.flatMap(NSImage.init(data:)), title: title)
    }

    static func pngData(document: PDFDocument, title: String) -> Data? {
        let image = document.page(at: 0)?.thumbnail(
            of: NSSize(width: size.width * 2, height: size.height * 2),
            for: .cropBox
        )
        return render(source: image, title: title)
    }

    private static func render(source: NSImage?, title: String) -> Data? {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width),
            pixelsHigh: Int(size.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        defer { NSGraphicsContext.restoreGraphicsState() }

        if let source, source.size.width > 0, source.size.height > 0 {
            NSColor.white.setFill()
            NSRect(origin: .zero, size: size).fill()
            let scale = max(size.width / source.size.width, size.height / source.size.height)
            let drawSize = NSSize(width: source.size.width * scale, height: source.size.height * scale)
            let target = NSRect(
                x: (size.width - drawSize.width) / 2,
                y: (size.height - drawSize.height) / 2,
                width: drawSize.width,
                height: drawSize.height
            )
            source.draw(in: target, from: .zero, operation: .copy, fraction: 1)
        } else {
            drawGeneratedCover(title: title)
        }

        return bitmap.representation(using: .png, properties: [:])
    }

    private static func drawGeneratedCover(title: String) {
        let hues: [CGFloat] = [0.03, 0.08, 0.14, 0.32, 0.52, 0.61, 0.73, 0.91]
        let seed = title.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7fff_ffff }
        let hue = hues[seed % hues.count]
        let background = NSColor(calibratedHue: hue, saturation: 0.42, brightness: 0.42, alpha: 1)
        background.setFill()
        NSRect(origin: .zero, size: size).fill()

        NSColor.white.withAlphaComponent(0.13).setFill()
        NSBezierPath(roundedRect: NSRect(x: 28, y: 30, width: 304, height: 460), xRadius: 4, yRadius: 4).fill()
        NSColor.white.withAlphaComponent(0.78).setFill()
        NSRect(x: 52, y: 116, width: 2, height: 286).fill()

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .left
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = 6
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未命名书籍" : title
        (cleanTitle as NSString).draw(
            with: NSRect(x: 76, y: 178, width: 230, height: 218),
            options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine],
            attributes: [
                .font: NSFont.systemFont(ofSize: cleanTitle.count > 18 ? 26 : 31, weight: .semibold),
                .foregroundColor: NSColor.white,
                .paragraphStyle: paragraph
            ]
        )
        ("READING COMPANION" as NSString).draw(
            at: NSPoint(x: 76, y: 92),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 9, weight: .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(0.72),
                .kern: 1.8
            ]
        )
    }
}
