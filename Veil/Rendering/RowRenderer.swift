import AppKit
import CoreText

private let defaultAttrs = CellAttributes()

nonisolated final class RowRenderer: @unchecked Sendable {
    private var cellSize: CGSize
    private let glyphCache: GlyphCache

    init(cellSize: CGSize, glyphCache: GlyphCache) {
        self.cellSize = cellSize
        self.glyphCache = glyphCache
    }

    func updateCellSize(_ newSize: CGSize) {
        self.cellSize = newSize
    }

    /// Render a single grid row to a CGImage.
    func render(
        row: [Cell],
        attributes: [Int: CellAttributes],
        defaultFg: Int,
        defaultBg: Int,
        scale: CGFloat = 2.0
    ) -> CGImage? {
        let cols = row.count
        guard cols > 0 else { return nil }

        let pointWidth = cellSize.width * CGFloat(cols)
        let pointHeight = cellSize.height
        let pixelWidth = Int(ceil(pointWidth * scale))
        let pixelHeight = Int(ceil(pointHeight * scale))
        guard pixelWidth > 0 && pixelHeight > 0 else { return nil }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.scaleBy(x: scale, y: scale)

        // Fill entire row with default background
        let defaultBgColor = NSColor(rgb: defaultBg)
        ctx.setFillColor(defaultBgColor.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: pointWidth, height: pointHeight))

        var col = 0
        while col < cols {
            let cell = row[col]
            let text = cell.text
            let attrs = attributes[cell.hlId] ?? defaultAttrs

            // Detect double-width character
            let isDoubleWidth = !text.isEmpty && text != " " && col + 1 < cols && row[col + 1].text.isEmpty
            let cellCount = isDoubleWidth ? 2 : 1
            let drawWidth = cellSize.width * CGFloat(cellCount)

            let x = CGFloat(col) * cellSize.width
            let cellRect = CGRect(x: x, y: 0, width: drawWidth, height: cellSize.height)

            let bg = attrs.effectiveBackground(defaultFg: defaultFg, defaultBg: defaultBg)

            // Fill cell background if different from default
            if bg != defaultBg {
                let bgColor = NSColor(rgb: bg)
                ctx.setFillColor(bgColor.cgColor)
                ctx.fill(cellRect)
            }

            // Skip rendering for spaces and empty text
            if text == " " || text.isEmpty {
                col += 1
                continue
            }

            // Get glyph image from cache and composite
            let glyphImage = glyphCache.get(text: text, attrs: attrs, defaultFg: defaultFg, defaultBg: defaultBg, cellCount: cellCount)
            ctx.draw(glyphImage, in: cellRect)

            col += cellCount
        }

        return ctx.makeImage()
    }
}
