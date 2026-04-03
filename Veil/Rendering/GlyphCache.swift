import AppKit
import CoreText

// MARK: - NSColor extensions

extension NSColor {
    nonisolated var intValue: Int {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
        let color = usingColorSpace(.sRGB) ?? self
        color.getRed(&r, green: &g, blue: &b, alpha: nil)
        return (Int(r * 255) << 16) | (Int(g * 255) << 8) | Int(b * 255)
    }

    nonisolated convenience init(rgb: Int) {
        self.init(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255.0,
            green: CGFloat((rgb >> 8) & 0xFF) / 255.0,
            blue: CGFloat(rgb & 0xFF) / 255.0,
            alpha: 1.0
        )
    }
}

// MARK: - GlyphCache

nonisolated final class GlyphCache: @unchecked Sendable {
    struct Key: Hashable {
        var text: String
        var fontName: String
        var fontSize: CGFloat
        var bold: Bool
        var italic: Bool
        var foreground: Int
        var background: Int
        var cellCount: Int
    }

    var scale: CGFloat = 2.0
    private var cache: [Key: CGImage] = [:]
    private var font: NSFont
    private var cellSize: CGSize

    init(font: NSFont, cellSize: CGSize) {
        self.font = font
        self.cellSize = cellSize
        FontFallback.probe()
    }

    func get(
        text: String, attrs: CellAttributes, defaultFg: Int, defaultBg: Int, cellCount: Int = 1
    ) -> CGImage {
        let fg = attrs.effectiveForeground(defaultFg: defaultFg, defaultBg: defaultBg)
        let bg = attrs.effectiveBackground(defaultFg: defaultFg, defaultBg: defaultBg)
        let key = Key(
            text: text,
            fontName: font.fontName,
            fontSize: font.pointSize,
            bold: attrs.bold,
            italic: attrs.italic,
            foreground: fg,
            background: bg,
            cellCount: cellCount
        )
        if let cached = cache[key] { return cached }
        let image = render(
            text: text, bold: attrs.bold, italic: attrs.italic, fg: fg, bg: bg, cellCount: cellCount
        )
        cache[key] = image
        return image
    }

    func invalidate() {
        cache.removeAll()
    }

    func updateFont(_ newFont: NSFont, cellSize newCellSize: CGSize) {
        self.font = newFont
        self.cellSize = newCellSize
        invalidate()
    }

    // MARK: - Private

    private func render(
        text: String, bold: Bool, italic: Bool, fg: Int, bg: Int, cellCount: Int = 1
    ) -> CGImage {
        let drawWidth = cellSize.width * CGFloat(cellCount)
        let pixelWidth = Int(ceil(drawWidth * scale))
        let pixelHeight = Int(ceil(cellSize.height * scale))
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(
            data: nil,
            width: max(pixelWidth, 1),
            height: max(pixelHeight, 1),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!

        ctx.scaleBy(x: scale, y: scale)

        // Fill background
        let bgColor = NSColor(rgb: bg)
        ctx.setFillColor(bgColor.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: drawWidth, height: cellSize.height))

        // Resolve font variant
        var drawFont = font
        if bold {
            let descriptor = drawFont.fontDescriptor.withSymbolicTraits(.bold)
            drawFont = NSFont(descriptor: descriptor, size: drawFont.pointSize) ?? drawFont
        }
        if italic {
            let descriptor = drawFont.fontDescriptor.withSymbolicTraits(.italic)
            drawFont = NSFont(descriptor: descriptor, size: drawFont.pointSize) ?? drawFont
        }

        drawFont = FontFallback.resolveFont(drawFont, for: text)

        // Draw text via CoreText
        let fgColor = NSColor(rgb: fg)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: drawFont,
            .foregroundColor: fgColor,
        ]
        let attrString = NSAttributedString(string: text, attributes: attributes)
        let line = CTLineCreateWithAttributedString(attrString)

        // Position baseline (centered in the potentially taller cell)
        let descent = CTFontGetDescent(drawFont)
        let leading = CTFontGetLeading(drawFont)
        let naturalHeight = CTFontGetAscent(drawFont) + descent + leading
        let extraPadding = (cellSize.height - naturalHeight) / 2
        let baselineY = descent + leading + extraPadding

        ctx.textPosition = CGPoint(x: 0, y: baselineY)
        CTLineDraw(line, ctx)

        return ctx.makeImage()!
    }
}
