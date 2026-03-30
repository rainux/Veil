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
                in metalLayer: CAMetalLayer) {
        guard let drawable = metalLayer.nextDrawable() else { return }

        var vertices: [Vertex] = []
        vertices.reserveCapacity(rows * cols * 6)

        let scale = Float(metalLayer.contentsScale)
        let cellW = Float(cellSize.width) * scale
        let cellH = Float(cellSize.height) * scale
        let topPad = Float(gridTopPadding) * scale

        let emptyRegion = GlyphAtlas.Region(u: 0, v: 0, uMax: 0, vMax: 0)

        for row in 0..<rows {
            for col in 0..<cols {
                let cell = cells[row][col]
                let attrs = attributes[cell.hlId] ?? CellAttributes()

                let fg = attrs.effectiveForeground(defaultFg: defaultFg, defaultBg: defaultBg)
                let bg = attrs.effectiveBackground(defaultFg: defaultFg, defaultBg: defaultBg)
                let bgColor = colorToSIMD4(bg)

                let x = Float(col) * cellW
                let y = topPad + Float(row) * cellH

                let text = cell.text
                if text == " " || text.isEmpty {
                    // Empty or space: only draw if bg differs from default
                    if bg != defaultBg {
                        addQuad(to: &vertices, x: x, y: y, w: cellW, h: cellH,
                                region: emptyRegion, bgColor: bgColor)
                    }
                } else {
                    // Check for double-width character
                    let isDoubleWidth = col + 1 < cols && cells[row][col + 1].text.isEmpty
                    let cellCount = isDoubleWidth ? 2 : 1
                    let quadW = cellW * Float(cellCount)

                    let region = atlas.region(text: text, font: font,
                                              bold: attrs.bold, italic: attrs.italic,
                                              fg: fg, bg: bg,
                                              cellSize: cellSize, cellCount: cellCount)
                    addQuad(to: &vertices, x: x, y: y, w: quadW, h: cellH,
                            region: region, bgColor: bgColor)
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
