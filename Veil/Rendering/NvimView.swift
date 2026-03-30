import AppKit
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
    let markedTextLayer = CATextLayer()
    var keyDownDone = true

    // MARK: - Private

    private let glyphCache: GlyphCache
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

        markedTextLayer.contentsScale = 2.0
        markedTextLayer.fontSize = 14
        markedTextLayer.foregroundColor = NSColor.white.cgColor
        markedTextLayer.backgroundColor = NSColor.darkGray.cgColor
        markedTextLayer.isHidden = true
        markedTextLayer.zPosition = 200
        layer?.addSublayer(markedTextLayer)
    }

    // MARK: - First responder

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        true
    }

    // MARK: - Rendering

    func render(grid: Grid) {
        let rows = grid.size.rows
        let cols = grid.size.cols

        // Ensure we have the right number of row layers
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

        // Configure scale for Retina rendering
        let screenScale = window?.backingScaleFactor ?? 2.0
        glyphCache.scale = screenScale

        // Render dirty rows
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
                // Flip Y: row 0 is at the top of the view, offset by gridTopPadding
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

        // Update cursor
        updateCursorPosition(grid.cursorPosition)

        // Store flat char indices for IME
        flatCharIndices = grid.flatCharIndices
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
            updateFont(font)
        } else {
            updateFont(NSFont.monospacedSystemFont(ofSize: size, weight: .regular))
        }
    }

    func updateFont(_ newFont: NSFont) {
        let newCellSize = NvimView.computeCellSize(for: newFont)
        cellSize = newCellSize
        glyphCache.updateFont(newFont, cellSize: newCellSize)
        rowRenderer.updateCellSize(newCellSize)
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
