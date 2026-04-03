import Metal
import MetalKit
import AppKit
import QuartzCore

nonisolated final class MetalRenderer {
    struct Vertex {
        var position: SIMD2<Float>  // pixel position
        var texCoord: SIMD2<Float>  // UV in atlas
        var fgColor: SIMD4<Float>  // foreground color (applied to glyph alpha mask)
        var bgColor: SIMD4<Float>  // background color
    }

    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let pipelineState: MTLRenderPipelineState

    // Pre-allocated vertex buffer to avoid per-frame MTLBuffer creation.
    // Rewritten each frame via contents() pointer instead of makeBuffer().
    private var vertexBuffer: MTLBuffer?
    private var vertexBufferCapacity: Int = 0

    // Persistent per-row vertex data for dirty-region rendering.
    // Only rows marked dirty are rebuilt; unchanged rows reuse cached vertices.
    // Each row's background and foreground vertices are stored separately.
    private var rowBackgroundVertices: [[Vertex]] = []
    private var rowForegroundVertices: [[Vertex]] = []
    private var cachedRows: Int = 0
    private var cachedCols: Int = 0

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw MetalRendererError.noDevice
        }
        self.device = device
        guard let queue = device.makeCommandQueue() else {
            throw MetalRendererError.noCommandQueue
        }
        self.commandQueue = queue

        guard let library = device.makeDefaultLibrary() else {
            throw MetalRendererError.noLibrary
        }
        let vertexFunction = library.makeFunction(name: "vertexShader")
        let fragmentFunction = library.makeFunction(name: "fragmentShader")

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        // Set up vertex descriptor for the vertex buffer layout
        let vertexDescriptor = MTLVertexDescriptor()
        // position: float2
        vertexDescriptor.attributes[0].format = .float2
        vertexDescriptor.attributes[0].offset = 0
        vertexDescriptor.attributes[0].bufferIndex = 0
        // texCoord: float2
        vertexDescriptor.attributes[1].format = .float2
        vertexDescriptor.attributes[1].offset = MemoryLayout<Float>.size * 2
        vertexDescriptor.attributes[1].bufferIndex = 0
        // fgColor: float4 (foreground color for glyph colorization in shader)
        vertexDescriptor.attributes[2].format = .float4
        vertexDescriptor.attributes[2].offset = MemoryLayout<Float>.size * 4
        vertexDescriptor.attributes[2].bufferIndex = 0
        // bgColor: float4
        vertexDescriptor.attributes[3].format = .float4
        vertexDescriptor.attributes[3].offset = MemoryLayout<Float>.size * 8
        vertexDescriptor.attributes[3].bufferIndex = 0
        // stride: 2 + 2 + 4 + 4 = 12 floats
        vertexDescriptor.layouts[0].stride = MemoryLayout<Float>.size * 12
        vertexDescriptor.layouts[0].stepRate = 1
        vertexDescriptor.layouts[0].stepFunction = .perVertex

        descriptor.vertexDescriptor = vertexDescriptor

        self.pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
    }

    // MARK: - Rendering

    func render(
        cells: [[Cell]], attributes: [Int: CellAttributes],
        rows: Int, cols: Int,
        dirtyRows: IndexSet,
        atlas: GlyphAtlas, font: NSFont, cellSize: CGSize,
        gridTopPadding: CGFloat, defaultFg: Int, defaultBg: Int,
        cursorPosition: Position, cursorShape: ModeInfo.CursorShape,
        cursorCellPercentage: Int,
        debugOverlay: String?,
        in metalLayer: CAMetalLayer
    ) {
        guard let drawable = metalLayer.nextDrawable() else { return }
        guard rows > 0, cols > 0, cells.count >= rows else { return }

        let scale = Float(metalLayer.contentsScale)
        let cellW = Float(cellSize.width) * scale
        let cellH = Float(cellSize.height) * scale
        let topPad = Float(gridTopPadding) * scale

        // Resize per-row caches when grid dimensions change
        resizeRowCaches(rows: rows, cols: cols)

        // Rebuild vertex data only for rows that Grid marked as dirty.
        // Cursor is drawn as an independent quad, so cursor movement alone
        // does not require rebuilding row vertices.
        for row in dirtyRows {
            guard row < rows, cells[row].count >= cols else { continue }
            rebuildRowVertices(
                row: row, cells: cells[row], attributes: attributes,
                cols: cols, atlas: atlas, font: font, cellSize: cellSize,
                cellW: cellW, cellH: cellH, topPad: topPad, scale: scale,
                defaultFg: defaultFg, defaultBg: defaultBg)
        }

        // Assemble final vertex array: all backgrounds first, then all foreground
        // glyphs, so glyph quads always draw on top of background quads.
        var vertices: [Vertex] = []
        vertices.reserveCapacity(rows * cols * 6)
        for row in 0..<rows {
            vertices.append(contentsOf: rowBackgroundVertices[row])
        }
        for row in 0..<rows {
            vertices.append(contentsOf: rowForegroundVertices[row])
        }

        // Cursor quad (always on top of everything)
        let emptyRegion = GlyphAtlas.Region(u: 0, v: 0, uMax: 0, vMax: 0, drawWidth: 0)
        let cx = Float(cursorPosition.col) * cellW
        var cy = topPad + Float(cursorPosition.row) * cellH
        var cw = cellW
        var ch = cellH
        let pct = Float(max(10, cursorCellPercentage)) / 100.0
        switch cursorShape {
        case .block:
            break
        case .vertical:
            cw = max(2 * scale, cellW * pct)
        case .horizontal:
            ch = max(2 * scale, cellH * pct)
            cy += cellH - ch  // Anchor horizontal bar at bottom of cell
        }
        var cursorColor = colorToSIMD4(defaultFg)
        cursorColor.w = 0.5
        addQuad(
            to: &vertices, x: cx, y: cy, w: cw, h: ch,
            region: emptyRegion, bgColor: cursorColor)

        guard !vertices.isEmpty else { return }

        guard let vertexBuffer = ensureVertexBuffer(vertexCount: vertices.count) else { return }
        let byteCount = vertices.count * MemoryLayout<Vertex>.stride
        memcpy(vertexBuffer.contents(), &vertices, byteCount)

        var uniforms = SIMD2<Float>(
            Float(metalLayer.drawableSize.width),
            Float(metalLayer.drawableSize.height))

        let passDescriptor = MTLRenderPassDescriptor()
        passDescriptor.colorAttachments[0].texture = drawable.texture
        passDescriptor.colorAttachments[0].loadAction = .clear
        passDescriptor.colorAttachments[0].clearColor = MTLClearColor(
            red: Double((defaultBg >> 16) & 0xFF) / 255.0,
            green: Double((defaultBg >> 8) & 0xFF) / 255.0,
            blue: Double(defaultBg & 0xFF) / 255.0,
            alpha: 1.0
        )
        passDescriptor.colorAttachments[0].storeAction = .store

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
            let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor)
        else { return }

        encoder.setRenderPipelineState(pipelineState)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<SIMD2<Float>>.size, index: 1)
        encoder.setFragmentTexture(atlas.texture, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count)

        if let debugOverlay {
            renderDebugOverlay(
                text: debugOverlay, scale: scale,
                encoder: encoder,
                viewportWidth: Float(metalLayer.drawableSize.width),
                viewportHeight: Float(metalLayer.drawableSize.height))
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func addQuad(
        to vertices: inout [Vertex],
        x: Float, y: Float, w: Float, h: Float,
        region: GlyphAtlas.Region,
        fgColor: SIMD4<Float> = SIMD4<Float>(0, 0, 0, 0),
        bgColor: SIMD4<Float>
    ) {
        // Two triangles forming a quad
        let v0 = Vertex(
            position: SIMD2(x, y), texCoord: SIMD2(region.u, region.v), fgColor: fgColor,
            bgColor: bgColor)
        let v1 = Vertex(
            position: SIMD2(x + w, y), texCoord: SIMD2(region.uMax, region.v), fgColor: fgColor,
            bgColor: bgColor)
        let v2 = Vertex(
            position: SIMD2(x, y + h), texCoord: SIMD2(region.u, region.vMax), fgColor: fgColor,
            bgColor: bgColor)
        let v3 = Vertex(
            position: SIMD2(x + w, y + h), texCoord: SIMD2(region.uMax, region.vMax),
            fgColor: fgColor, bgColor: bgColor)
        vertices.append(v0)
        vertices.append(v1)
        vertices.append(v2)
        vertices.append(v1)
        vertices.append(v3)
        vertices.append(v2)
    }

    // MARK: - Debug Overlay

    private func renderDebugOverlay(
        text: String, scale: Float,
        encoder: MTLRenderCommandEncoder,
        viewportWidth: Float, viewportHeight: Float
    ) {
        // Render debug text into a CGImage using CoreText
        let font = NSFont.monospacedSystemFont(ofSize: 18, weight: .regular)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 2
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraphStyle,
        ]
        let attrString = NSAttributedString(string: text, attributes: attrs)

        // Measure text size using CTFramesetter (thread-safe, no AppKit dependency)
        let cfAttrString = attrString as CFAttributedString
        let framesetter = CTFramesetterCreateWithAttributedString(cfAttrString)
        let textRect = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(location: 0, length: 0),
            nil, CGSize(width: 1024, height: 748), nil
        )

        let padding: CGFloat = 8
        let width = ceil(textRect.width + padding * 2)
        let height = ceil(textRect.height + padding * 2)
        let pixelW = Int(width * CGFloat(scale))
        let pixelH = Int(height * CGFloat(scale))
        guard pixelW > 0, pixelH > 0 else { return }

        // Render to CGContext
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard
            let ctx = CGContext(
                data: nil, width: pixelW, height: pixelH,
                bitsPerComponent: 8, bytesPerRow: pixelW * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return }

        ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))

        // Semi-transparent dark background with rounded corners
        let bgRect = CGRect(x: 0, y: 0, width: width, height: height)
        ctx.setFillColor(NSColor(white: 0, alpha: 0.7).cgColor)
        let path = CGPath(roundedRect: bgRect, cornerWidth: 6, cornerHeight: 6, transform: nil)
        ctx.addPath(path)
        ctx.fillPath()

        // Draw text (flip coordinates for NSAttributedString drawing)
        let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsCtx
        ctx.saveGState()
        ctx.translateBy(x: 0, y: height)
        ctx.scaleBy(x: 1, y: -1)
        let drawRect = CGRect(
            x: padding, y: padding, width: textRect.width, height: textRect.height)
        attrString.draw(in: drawRect)
        ctx.restoreGState()
        NSGraphicsContext.restoreGraphicsState()

        guard let image = ctx.makeImage() else { return }

        // Create temporary texture from rendered image
        let texDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: pixelW, height: pixelH,
            mipmapped: false)
        texDesc.usage = .shaderRead
        texDesc.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: texDesc),
            let data = image.dataProvider?.data,
            let bytes = CFDataGetBytePtr(data)
        else { return }
        texture.replace(
            region: MTLRegionMake2D(0, 0, pixelW, pixelH),
            mipmapLevel: 0, withBytes: bytes, bytesPerRow: pixelW * 4)

        // Position at top-left with margin
        let margin: Float = 10 * scale
        let quadW = Float(width) * scale
        let quadH = Float(height) * scale
        let x = margin
        let y = margin

        // Draw overlay quad using the overlay texture
        var overlayVertices: [Vertex] = []
        let region = GlyphAtlas.Region(u: 0, v: 0, uMax: 1, vMax: 1, drawWidth: Float(width))
        addQuad(
            to: &overlayVertices, x: x, y: y, w: quadW, h: quadH,
            region: region, bgColor: SIMD4<Float>(0, 0, 0, 0))

        let bufferSize = overlayVertices.count * MemoryLayout<Vertex>.stride
        guard
            let vertexBuffer = device.makeBuffer(
                bytes: overlayVertices, length: bufferSize,
                options: .storageModeShared)
        else { return }

        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: overlayVertices.count)
    }

    // MARK: - Dirty-region helpers

    /// Reset per-row vertex caches when the grid dimensions change.
    private func resizeRowCaches(rows: Int, cols: Int) {
        guard rows != cachedRows || cols != cachedCols else { return }
        rowBackgroundVertices = Array(repeating: [], count: rows)
        rowForegroundVertices = Array(repeating: [], count: rows)
        cachedRows = rows
        cachedCols = cols
    }

    /// Rebuild background and foreground vertices for a single row.
    /// Called only for dirty rows, avoiding redundant work on unchanged content.
    ///
    /// Two-pass rendering (WezTerm-style): backgrounds first, then foreground
    /// glyphs on top. This allows glyphs to overflow into adjacent cells
    /// without being covered by the neighbor's background quad. Nerd font
    /// icons whose bounding box exceeds the cell width are handled as:
    ///   - Followed by space: render at natural width (overflow into space)
    ///   - Followed by content: scale down to fit cell (better than clipping)
    private func rebuildRowVertices(
        row: Int, cells: [Cell], attributes: [Int: CellAttributes],
        cols: Int, atlas: GlyphAtlas, font: NSFont, cellSize: CGSize,
        cellW: Float, cellH: Float, topPad: Float, scale: Float,
        defaultFg: Int, defaultBg: Int
    ) {
        let emptyRegion = GlyphAtlas.Region(u: 0, v: 0, uMax: 0, vMax: 0, drawWidth: 0)
        let transparentBg = SIMD4<Float>(0, 0, 0, 0)
        let y = topPad + Float(row) * cellH

        // Background pass
        var bgVerts: [Vertex] = []
        var col = 0
        while col < cols {
            let cell = cells[col]
            let attrs = attributes[cell.hlId] ?? CellAttributes()
            let bg = attrs.effectiveBackground(defaultFg: defaultFg, defaultBg: defaultBg)
            let x = Float(col) * cellW
            let text = cell.text
            if text.isEmpty {
                // Double-width placeholder, skip
                col += 1
            } else {
                let isDoubleWidth = col + 1 < cols && cells[col + 1].text.isEmpty
                let cellCount = isDoubleWidth ? 2 : 1
                if bg != defaultBg {
                    let quadW = cellW * Float(cellCount)
                    addQuad(
                        to: &bgVerts, x: x, y: y, w: quadW, h: cellH,
                        region: emptyRegion, bgColor: colorToSIMD4(bg))
                }
                col += cellCount
            }
        }
        rowBackgroundVertices[row] = bgVerts

        // Foreground glyph pass: atlas stores white alpha masks, so we pass
        // the per-cell foreground color for the shader to apply
        var fgVerts: [Vertex] = []
        col = 0
        while col < cols {
            let cell = cells[col]
            let text = cell.text
            if text.isEmpty || text == " " {
                col += 1
                continue
            }

            let attrs = attributes[cell.hlId] ?? CellAttributes()
            let fg = attrs.effectiveForeground(defaultFg: defaultFg, defaultBg: defaultBg)
            let fgSIMD = colorToSIMD4(fg)
            let x = Float(col) * cellW

            let isDoubleWidth = col + 1 < cols && cells[col + 1].text.isEmpty
            let cellCount = isDoubleWidth ? 2 : 1
            let allocatedW = cellW * Float(cellCount)

            let region = atlas.region(
                text: text, font: font,
                bold: attrs.bold, italic: attrs.italic,
                cellSize: cellSize, cellCount: cellCount)

            let glyphW = region.drawWidth * Float(atlas.scale)
            if glyphW > allocatedW {
                // Glyph wider than allocated cells: overflow or scale down
                let nextCol = col + cellCount
                let followedBySpace = nextCol < cols && cells[nextCol].text == " "
                if followedBySpace {
                    // Overflow into the adjacent space (natural size)
                    addQuad(
                        to: &fgVerts, x: x, y: y, w: glyphW, h: cellH,
                        region: region, fgColor: fgSIMD, bgColor: transparentBg)
                } else {
                    // No room to overflow: squeeze into allocated width
                    addQuad(
                        to: &fgVerts, x: x, y: y, w: allocatedW, h: cellH,
                        region: region, fgColor: fgSIMD, bgColor: transparentBg)
                }
            } else {
                addQuad(
                    to: &fgVerts, x: x, y: y, w: allocatedW, h: cellH,
                    region: region, fgColor: fgSIMD, bgColor: transparentBg)
            }
            col += cellCount
        }
        rowForegroundVertices[row] = fgVerts
    }

    /// Ensure the pre-allocated vertex buffer is large enough for the given vertex count.
    /// Grows by 2x when capacity is exceeded to amortize reallocation cost.
    private func ensureVertexBuffer(vertexCount: Int) -> MTLBuffer? {
        let requiredBytes = vertexCount * MemoryLayout<Vertex>.stride
        if let buffer = vertexBuffer, vertexBufferCapacity >= requiredBytes {
            return buffer
        }
        // Grow to at least 2x current capacity to avoid frequent reallocation
        let newCapacity = max(requiredBytes, vertexBufferCapacity * 2)
        guard let buffer = device.makeBuffer(length: newCapacity, options: .storageModeShared)
        else {
            return nil
        }
        vertexBuffer = buffer
        vertexBufferCapacity = newCapacity
        return buffer
    }

    private func colorToSIMD4(_ rgb: Int) -> SIMD4<Float> {
        SIMD4<Float>(
            Float((rgb >> 16) & 0xFF) / 255.0,
            Float((rgb >> 8) & 0xFF) / 255.0,
            Float(rgb & 0xFF) / 255.0,
            1.0
        )
    }
}

enum MetalRendererError: Error {
    case noDevice
    case noCommandQueue
    case noLibrary
}
