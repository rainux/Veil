import Metal
import MetalKit
import AppKit
import QuartzCore

nonisolated final class MetalRenderer {
    struct Vertex {
        var position: SIMD2<Float>   // pixel position
        var texCoord: SIMD2<Float>   // UV in atlas
        var bgColor: SIMD4<Float>    // background color
    }

    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let pipelineState: MTLRenderPipelineState

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
        // bgColor: float4
        vertexDescriptor.attributes[2].format = .float4
        vertexDescriptor.attributes[2].offset = MemoryLayout<Float>.size * 4
        vertexDescriptor.attributes[2].bufferIndex = 0
        // stride: 2 + 2 + 4 = 8 floats
        vertexDescriptor.layouts[0].stride = MemoryLayout<Float>.size * 8
        vertexDescriptor.layouts[0].stepRate = 1
        vertexDescriptor.layouts[0].stepFunction = .perVertex

        descriptor.vertexDescriptor = vertexDescriptor

        self.pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
    }

    // MARK: - Rendering

    func render(cells: [[Cell]], attributes: [Int: CellAttributes],
                rows: Int, cols: Int,
                atlas: GlyphAtlas, font: NSFont, cellSize: CGSize,
                gridTopPadding: CGFloat, defaultFg: Int, defaultBg: Int,
                cursorPosition: Position, cursorShape: ModeInfo.CursorShape,
                cursorCellPercentage: Int,
                debugOverlay: String?,
                in metalLayer: CAMetalLayer) {
        guard let drawable = metalLayer.nextDrawable() else { return }
        guard rows > 0, cols > 0, cells.count >= rows else { return }

        var vertices: [Vertex] = []
        vertices.reserveCapacity(rows * cols * 6)

        let scale = Float(metalLayer.contentsScale)
        let cellW = Float(cellSize.width) * scale
        let cellH = Float(cellSize.height) * scale
        let topPad = Float(gridTopPadding) * scale

        let emptyRegion = GlyphAtlas.Region(u: 0, v: 0, uMax: 0, vMax: 0)

        for row in 0..<rows {
            guard cells[row].count >= cols else { continue }
            var col = 0
            while col < cols {
                let cell = cells[row][col]
                let attrs = attributes[cell.hlId] ?? CellAttributes()

                let fg = attrs.effectiveForeground(defaultFg: defaultFg, defaultBg: defaultBg)
                let bg = attrs.effectiveBackground(defaultFg: defaultFg, defaultBg: defaultBg)
                let bgColor = colorToSIMD4(bg)

                let x = Float(col) * cellW
                let y = topPad + Float(row) * cellH

                let text = cell.text
                if text.isEmpty {
                    // Empty cell = double-width placeholder, skip.
                    col += 1
                } else if text == " " {
                    if bg != defaultBg {
                        addQuad(to: &vertices, x: x, y: y, w: cellW, h: cellH,
                                region: emptyRegion, bgColor: bgColor)
                    }
                    col += 1
                } else {
                    // Check for double-width character (next cell is empty placeholder)
                    let isDoubleWidth = col + 1 < cols && cells[row][col + 1].text.isEmpty
                    let cellCount = isDoubleWidth ? 2 : 1
                    let quadW = cellW * Float(cellCount)

                    let region = atlas.region(text: text, font: font,
                                              bold: attrs.bold, italic: attrs.italic,
                                              fg: fg, bg: bg,
                                              cellSize: cellSize, cellCount: cellCount)
                    addQuad(to: &vertices, x: x, y: y, w: quadW, h: cellH,
                            region: region, bgColor: bgColor)
                    col += cellCount  // Skip placeholder cell for double-width
                }
            }
        }

        // Cursor quad
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
        addQuad(to: &vertices, x: cx, y: cy, w: cw, h: ch,
                region: emptyRegion, bgColor: cursorColor)

        guard !vertices.isEmpty else { return }

        let bufferSize = vertices.count * MemoryLayout<Vertex>.stride
        guard let vertexBuffer = device.makeBuffer(bytes: vertices, length: bufferSize,
                                                    options: .storageModeShared) else { return }

        var uniforms = SIMD2<Float>(Float(metalLayer.drawableSize.width),
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
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else { return }

        encoder.setRenderPipelineState(pipelineState)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<SIMD2<Float>>.size, index: 1)
        encoder.setFragmentTexture(atlas.texture, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count)

        if let debugOverlay {
            renderDebugOverlay(text: debugOverlay, scale: scale,
                               encoder: encoder,
                               viewportWidth: Float(metalLayer.drawableSize.width),
                               viewportHeight: Float(metalLayer.drawableSize.height))
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func addQuad(to vertices: inout [Vertex],
                         x: Float, y: Float, w: Float, h: Float,
                         region: GlyphAtlas.Region, bgColor: SIMD4<Float>) {
        // Two triangles forming a quad
        vertices.append(Vertex(position: SIMD2(x, y), texCoord: SIMD2(region.u, region.v), bgColor: bgColor))
        vertices.append(Vertex(position: SIMD2(x + w, y), texCoord: SIMD2(region.uMax, region.v), bgColor: bgColor))
        vertices.append(Vertex(position: SIMD2(x, y + h), texCoord: SIMD2(region.u, region.vMax), bgColor: bgColor))
        vertices.append(Vertex(position: SIMD2(x + w, y), texCoord: SIMD2(region.uMax, region.v), bgColor: bgColor))
        vertices.append(Vertex(position: SIMD2(x + w, y + h), texCoord: SIMD2(region.uMax, region.vMax), bgColor: bgColor))
        vertices.append(Vertex(position: SIMD2(x, y + h), texCoord: SIMD2(region.u, region.vMax), bgColor: bgColor))
    }

    // MARK: - Debug Overlay

    private func renderDebugOverlay(text: String, scale: Float,
                                     encoder: MTLRenderCommandEncoder,
                                     viewportWidth: Float, viewportHeight: Float) {
        // Render debug text into a CGImage using CoreText
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 2
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraphStyle,
        ]
        let attrString = NSAttributedString(string: text, attributes: attrs)

        // Measure text size
        let textStorage = NSTextStorage(attributedString: attrString)
        let textContainer = NSTextContainer(size: NSSize(width: 300, height: 500))
        let layoutManager = NSLayoutManager()
        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)
        let textRect = layoutManager.usedRect(for: textContainer)

        let padding: CGFloat = 8
        let width = ceil(textRect.width + padding * 2)
        let height = ceil(textRect.height + padding * 2)
        let pixelW = Int(width * CGFloat(scale))
        let pixelH = Int(height * CGFloat(scale))
        guard pixelW > 0, pixelH > 0 else { return }

        // Render to CGContext
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: pixelW, height: pixelH,
                                  bitsPerComponent: 8, bytesPerRow: pixelW * 4,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return }

        ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))

        // Semi-transparent dark background with rounded corners
        let bgRect = CGRect(x: 0, y: 0, width: width, height: height)
        ctx.setFillColor(NSColor(white: 0, alpha: 0.7).cgColor)
        let path = CGPath(roundedRect: bgRect, cornerWidth: 6, cornerHeight: 6, transform: nil)
        ctx.addPath(path)
        ctx.fillPath()

        // Draw text (flip coordinates for NSAttributedString drawing)
        ctx.saveGState()
        ctx.translateBy(x: 0, y: height)
        ctx.scaleBy(x: 1, y: -1)
        let drawRect = CGRect(x: padding, y: padding, width: textRect.width, height: textRect.height)
        attrString.draw(in: drawRect)
        ctx.restoreGState()

        guard let image = ctx.makeImage() else { return }

        // Create temporary texture from rendered image
        let texDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                                width: pixelW, height: pixelH,
                                                                mipmapped: false)
        texDesc.usage = .shaderRead
        texDesc.storageMode = .managed
        guard let texture = device.makeTexture(descriptor: texDesc),
              let data = image.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else { return }
        texture.replace(region: MTLRegionMake2D(0, 0, pixelW, pixelH),
                        mipmapLevel: 0, withBytes: bytes, bytesPerRow: pixelW * 4)

        // Position at top-right with margin
        let margin: Float = 10 * scale
        let quadW = Float(width) * scale
        let quadH = Float(height) * scale
        let x = viewportWidth - quadW - margin
        let y = margin

        // Draw overlay quad using the overlay texture
        var overlayVertices: [Vertex] = []
        let region = GlyphAtlas.Region(u: 0, v: 0, uMax: 1, vMax: 1)
        addQuad(to: &overlayVertices, x: x, y: y, w: quadW, h: quadH,
                region: region, bgColor: SIMD4<Float>(0, 0, 0, 0))

        let bufferSize = overlayVertices.count * MemoryLayout<Vertex>.stride
        guard let vertexBuffer = device.makeBuffer(bytes: overlayVertices, length: bufferSize,
                                                    options: .storageModeShared) else { return }

        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: overlayVertices.count)
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
