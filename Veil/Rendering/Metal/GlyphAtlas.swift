import Metal
import AppKit
import CoreText

nonisolated final class GlyphAtlas {
    struct Region {
        let u: Float      // left UV (0-1)
        let v: Float      // top UV (0-1)
        let uMax: Float   // right UV
        let vMax: Float   // bottom UV
    }

    // Use same key as GlyphCache for consistency
    struct Key: Hashable {
        let text: String
        let fontName: String
        let fontSize: CGFloat
        let bold: Bool
        let italic: Bool
        let foreground: Int
        let background: Int
        let cellCount: Int
    }

    private let device: MTLDevice
    private(set) var texture: MTLTexture!
    private var regions: [Key: Region] = [:]
    private var nextX: Int = 0
    private var nextY: Int = 0
    private var currentRowHeight: Int = 0
    private let atlasWidth: Int
    private let atlasHeight: Int
    var scale: CGFloat = 2.0

    init(device: MTLDevice, size: Int = 2048) {
        self.device = device
        self.atlasWidth = size
        self.atlasHeight = size
        self.texture = createTexture(size: size)
    }

    func region(text: String, font: NSFont, bold: Bool, italic: Bool,
                fg: Int, bg: Int, cellSize: CGSize, cellCount: Int = 1) -> Region {
        let key = Key(text: text, fontName: font.fontName, fontSize: font.pointSize,
                      bold: bold, italic: italic, foreground: fg, background: bg,
                      cellCount: cellCount)

        if let existing = regions[key] { return existing }

        // Render glyph to CGContext
        let drawWidth = cellSize.width * CGFloat(cellCount)
        let pixelW = Int(ceil(drawWidth * scale))
        let pixelH = Int(ceil(cellSize.height * scale))

        // Check if we need to move to next row
        if nextX + pixelW > atlasWidth {
            nextX = 0
            nextY += currentRowHeight
            currentRowHeight = 0
        }

        // Check if atlas is full (for now just reset — could grow later)
        if nextY + pixelH > atlasHeight {
            invalidate()
        }

        // Render glyph
        let imageData = renderGlyph(text: text, font: font, bold: bold, italic: italic,
                                     fg: fg, bg: bg, width: pixelW, height: pixelH,
                                     drawWidth: drawWidth, cellHeight: cellSize.height)

        // Copy to atlas texture
        let mtlRegion = MTLRegionMake2D(nextX, nextY, pixelW, pixelH)
        texture.replace(region: mtlRegion, mipmapLevel: 0,
                        withBytes: imageData, bytesPerRow: pixelW * 4)

        // Calculate UV coordinates
        let uvRegion = Region(
            u: Float(nextX) / Float(atlasWidth),
            v: Float(nextY) / Float(atlasHeight),
            uMax: Float(nextX + pixelW) / Float(atlasWidth),
            vMax: Float(nextY + pixelH) / Float(atlasHeight)
        )

        regions[key] = uvRegion
        nextX += pixelW
        currentRowHeight = max(currentRowHeight, pixelH)

        return uvRegion
    }

    func invalidate() {
        regions.removeAll()
        nextX = 0
        nextY = 0
        currentRowHeight = 0
        // Clear texture
        texture = createTexture(size: atlasWidth)
    }

    // MARK: - Private

    private func createTexture(size: Int) -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: size, height: size,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .managed  // CPU-writable, GPU-readable on macOS
        return device.makeTexture(descriptor: descriptor)!
    }

    private func renderGlyph(text: String, font: NSFont, bold: Bool, italic: Bool,
                              fg: Int, bg: Int, width: Int, height: Int,
                              drawWidth: CGFloat, cellHeight: CGFloat) -> [UInt8] {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        // premultipliedFirst + byteOrder32Little = BGRA byte order, matching .bgra8Unorm
        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return Array(repeating: 0, count: width * height * 4) }

        ctx.scaleBy(x: scale, y: scale)

        // Fill background
        let bgColor = NSColor(rgb: bg)
        ctx.setFillColor(bgColor.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: drawWidth, height: cellHeight))

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
        let extraPadding = (cellHeight - naturalHeight) / 2
        let baselineY = descent + leading + extraPadding

        ctx.textPosition = CGPoint(x: 0, y: baselineY)
        CTLineDraw(line, ctx)

        // Extract pixel data
        guard let data = ctx.data else { return Array(repeating: 0, count: width * height * 4) }
        return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self),
                                         count: width * height * 4))
    }
}
