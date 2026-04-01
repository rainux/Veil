import AppKit
import Metal
import QuartzCore

@MainActor
final class NvimView: NSView {
    // MARK: - Public properties

    var channel: NvimChannel?
    var gridFont: NSFont {
        didSet { updateFont(gridFont) }
    }
    var cellSize: CGSize
    var defaultFg: Int = 0x000000
    var defaultBg: Int
    var flatCharIndices: [[Int]] = []
    var modeInfoList: [ModeInfo] = []
    var currentCursorShape: ModeInfo.CursorShape = .block
    var currentCursorCellPercentage: Int = 100

    // MARK: - Scroll state

    var scrollDeltaY: CGFloat = 0
    var lastScrollLines: Int = 0

    // MARK: - Internal (accessed by keyboard extension)

    let cursorLayer = CALayer()
    var rowLayers: [CALayer] = []
    var markedText: String?
    var markedPosition: Position = .zero
    let markedLayer = CALayer()
    var keyDownDone = true

    // MARK: - Metal

    var metalRenderer: MetalRenderer?
    var metalLayer: CAMetalLayer?
    var glyphAtlas: GlyphAtlas?

    // MARK: - Debug overlay

    var debugOverlayEnabled = false
    private var lastRenderTime: CFAbsoluteTime = 0
    private var currentFPS: Int = 0

    // MARK: - Private

    let glyphCache: GlyphCache
    private let rowRenderer: RowRenderer

    // MARK: - Init

    override init(frame: NSRect) {
        let defaultFont = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        self.gridFont = defaultFont
        let size = NvimView.computeCellSize(for: defaultFont)
        self.cellSize = size
        self.defaultBg = NSColor.windowBackgroundColor.intValue
        self.glyphCache = GlyphCache(font: defaultFont, cellSize: size)
        self.rowRenderer = RowRenderer(cellSize: size, glyphCache: glyphCache)
        super.init(frame: frame)
        setupLayers()
    }

    required init?(coder: NSCoder) {
        let defaultFont = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        self.gridFont = defaultFont
        let size = NvimView.computeCellSize(for: defaultFont)
        self.cellSize = size
        self.defaultBg = NSColor.windowBackgroundColor.intValue
        self.glyphCache = GlyphCache(font: defaultFont, cellSize: size)
        self.rowRenderer = RowRenderer(cellSize: size, glyphCache: glyphCache)
        super.init(coder: coder)
        setupLayers()
    }

    private func setupLayers() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        cursorLayer.zPosition = 100
        cursorLayer.backgroundColor = NSColor(rgb: defaultFg).cgColor
        layer?.addSublayer(cursorLayer)

        markedLayer.isHidden = true
        markedLayer.zPosition = 200
        layer?.addSublayer(markedLayer)

        // Metal layer for GPU-accelerated grid rendering
        do {
            let renderer = try MetalRenderer()
            let atlas = GlyphAtlas(device: renderer.device)
            let metal = CAMetalLayer()
            metal.device = renderer.device
            metal.pixelFormat = .bgra8Unorm
            metal.framebufferOnly = true
            metal.isHidden = true
            layer?.addSublayer(metal)
            self.metalRenderer = renderer
            self.glyphAtlas = atlas
            self.metalLayer = metal
        } catch {
            // Metal not available — fall back to CoreText rendering
        }
    }

    // MARK: - First responder

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        true
    }

    // MARK: - Rendering

    func render(grid: Grid) {
        // Update state
        defaultFg = grid.defaultForeground
        defaultBg = grid.defaultBackground
        flatCharIndices = grid.flatCharIndices

        if let metalRenderer, let metalLayer, let glyphAtlas {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            metalLayer.isHidden = false
            for rl in rowLayers { rl.isHidden = true }
            cursorLayer.isHidden = true

            metalLayer.frame = bounds
            metalLayer.contentsScale = window?.backingScaleFactor ?? 2.0
            metalLayer.drawableSize = CGSize(
                width: bounds.width * metalLayer.contentsScale,
                height: bounds.height * metalLayer.contentsScale
            )
            CATransaction.commit()
            glyphAtlas.scale = metalLayer.contentsScale

            // FPS tracking
            let now = CFAbsoluteTimeGetCurrent()
            if lastRenderTime > 0 {
                let delta = now - lastRenderTime
                if delta > 0 { currentFPS = Int(1.0 / delta) }
            }
            lastRenderTime = now

            // Build debug overlay text if enabled
            let debugText: String? = debugOverlayEnabled ? """
            Renderer: Metal (\(metalRenderer.device.name))
            FPS: \(currentFPS)
            Grid: \(grid.size.cols)×\(grid.size.rows)
            Atlas: \(glyphAtlas.regionCount)
            """ : nil

            metalRenderer.render(
                cells: grid.cells, attributes: grid.attributes,
                rows: grid.size.rows, cols: grid.size.cols,
                atlas: glyphAtlas, font: gridFont,
                cellSize: cellSize, gridTopPadding: Self.gridTopPadding,
                defaultFg: defaultFg, defaultBg: defaultBg,
                cursorPosition: grid.cursorPosition,
                cursorShape: currentCursorShape,
                cursorCellPercentage: currentCursorCellPercentage,
                debugOverlay: debugText,
                in: metalLayer
            )
        } else {
            // Fallback: old CoreText rendering
            let rows = grid.size.rows
            let cols = grid.size.cols

            while rowLayers.count < rows {
                let rowLayer = CALayer()
                rowLayer.contentsScale = window?.backingScaleFactor ?? 2.0
                rowLayer.magnificationFilter = .nearest
                layer?.addSublayer(rowLayer)
                rowLayers.append(rowLayer)
            }
            while rowLayers.count > rows {
                rowLayers.removeLast().removeFromSuperlayer()
            }

            let screenScale = window?.backingScaleFactor ?? 2.0
            glyphCache.scale = screenScale

            for rowIdx in grid.dirtyRows {
                guard rowIdx < rows else { continue }
                let rowCells = grid.cells[rowIdx]
                if let image = rowRenderer.render(
                    row: rowCells,
                    attributes: grid.attributes,
                    defaultFg: grid.defaultForeground,
                    defaultBg: grid.defaultBackground,
                    scale: screenScale
                ) {
                    let rowLayer = rowLayers[rowIdx]
                    let y = bounds.height - CGFloat(rowIdx + 1) * cellSize.height - Self.gridTopPadding
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    rowLayer.frame = CGRect(
                        x: 0, y: y,
                        width: cellSize.width * CGFloat(cols),
                        height: cellSize.height
                    )
                    rowLayer.contents = image
                    CATransaction.commit()
                }
            }

            updateCursorPosition(grid.cursorPosition)
        }

        layer?.backgroundColor = NSColor(rgb: defaultBg).cgColor
    }

    // MARK: - Cursor

    private func updateCursorPosition(_ pos: Position) {
        let x: CGFloat
        let y = bounds.height - CGFloat(pos.row + 1) * cellSize.height - Self.gridTopPadding
        let width: CGFloat
        let height: CGFloat

        switch currentCursorShape {
        case .block:
            x = CGFloat(pos.col) * cellSize.width
            width = cellSize.width
            height = cellSize.height
        case .vertical:
            x = CGFloat(pos.col) * cellSize.width
            width = max(2, cellSize.width * CGFloat(currentCursorCellPercentage) / 100.0)
            height = cellSize.height
        case .horizontal:
            x = CGFloat(pos.col) * cellSize.width
            width = cellSize.width
            height = max(2, cellSize.height * CGFloat(currentCursorCellPercentage) / 100.0)
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cursorLayer.frame = CGRect(x: x, y: y, width: width, height: height)
        cursorLayer.isHidden = false
        CATransaction.commit()
    }

    // MARK: - Grid sizing

    func gridSizeForViewSize(_ viewSize: CGSize) -> GridSize {
        let cols = max(1, Int(floor(viewSize.width / cellSize.width)))
        let rows = max(1, Int(floor((viewSize.height - Self.gridTopPadding) / cellSize.height)))
        return GridSize(rows: rows, cols: cols)
    }

    // MARK: - Font

    func parseAndSetGuifont(_ guifont: String) {
        let parts = guifont.split(separator: ":")
        guard let fontName = parts.first.map(String.init) else { return }
        var size: CGFloat = 14
        for part in parts.dropFirst() {
            if part.hasPrefix("h"), let s = Double(part.dropFirst()) {
                size = CGFloat(s)
            }
        }
        let cleanName = fontName.replacingOccurrences(of: "\\ ", with: " ")
            .replacingOccurrences(of: "_", with: " ")
        if let font = NSFont(name: cleanName, size: size) {
            gridFont = font  // triggers didSet → updateFont
        } else {
            gridFont = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        }
    }

    func updateFont(_ newFont: NSFont) {
        let newCellSize = NvimView.computeCellSize(for: newFont)
        cellSize = newCellSize
        glyphCache.updateFont(newFont, cellSize: newCellSize)
        rowRenderer.updateCellSize(newCellSize)
        glyphAtlas?.invalidate()
    }

    private static let lineHeightMultiplier: CGFloat = 1.2
    static let gridTopPadding: CGFloat = 8

    private static func computeCellSize(for font: NSFont) -> CGSize {
        let glyph = font.glyph(withName: "M")
        let advancement = font.advancement(forGlyph: glyph)
        let width = advancement.width > 0 ? advancement.width : font.pointSize * 0.6
        let height = ceil((CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)) * lineHeightMultiplier)
        return CGSize(width: ceil(width), height: height)
    }

    // MARK: - Colors

    func setDefaultColors(fg: Int, bg: Int) {
        defaultFg = fg
        defaultBg = bg
        layer?.backgroundColor = NSColor(rgb: bg).cgColor
        cursorLayer.backgroundColor = NSColor(rgb: fg).cgColor
    }

    // MARK: - Mode info

    func updateModeInfo(_ list: [ModeInfo]) {
        modeInfoList = list
    }

    func updateCursorMode(_ modeIdx: Int) {
        guard modeIdx >= 0 && modeIdx < modeInfoList.count else { return }
        let info = modeInfoList[modeIdx]
        currentCursorShape = info.cursorShape
        currentCursorCellPercentage = info.cellPercentage > 0 ? info.cellPercentage : 100
    }

    // MARK: - Coordinate conversion

    func gridPosition(for point: NSPoint) -> Position {
        let col = Int(point.x / cellSize.width)
        let row = Int((bounds.height - point.y) / cellSize.height)
        return Position(row: max(0, row), col: max(0, col))
    }
}
