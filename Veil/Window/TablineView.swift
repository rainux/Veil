import AppKit

class TablineView: NSView {

    struct Tab {
        var handle: Int
        var name: String
        var isSelected: Bool
    }

    private(set) var tabs: [Tab] = []
    var onSelectTab: ((Int) -> Void)?
    var bgColor: NSColor = NSColor.windowBackgroundColor
    var fgColor: NSColor = NSColor.labelColor

    private let tabHeight: CGFloat = 28
    private let maxTabWidth: CGFloat = 200

    private var heightConstraint: NSLayoutConstraint!

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        heightConstraint = heightAnchor.constraint(equalToConstant: 0)
        heightConstraint.isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func update(current: Int, tabInfos: [TabpageInfo]) {
        tabs = tabInfos.map { info in
            Tab(handle: info.handle, name: info.name, isSelected: info.handle == current)
        }
        let newHeight: CGFloat = tabHeight
        if heightConstraint.constant != newHeight {
            heightConstraint.constant = newHeight
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !tabs.isEmpty else { return }

        bgColor.setFill()
        bounds.fill()

        // Titlebar shadow: subtle gradient at the top of the tab bar
        let shadowHeight: CGFloat = 3
        let shadowRect = NSRect(
            x: 0, y: bounds.maxY - shadowHeight, width: bounds.width, height: shadowHeight)
        if let gradient = NSGradient(
            starting: NSColor.black.withAlphaComponent(0.15), ending: .clear)
        {
            gradient.draw(in: shadowRect, angle: 270)
        }

        let tabWidth = min(bounds.width / CGFloat(tabs.count), maxTabWidth)

        for (i, tab) in tabs.enumerated() {
            let rect = CGRect(x: CGFloat(i) * tabWidth, y: 0, width: tabWidth, height: tabHeight)

            if tab.isSelected {
                NSColor.controlAccentColor.withAlphaComponent(0.2).setFill()
                let rounded = NSBezierPath(
                    roundedRect: rect.insetBy(dx: 2, dy: 3), xRadius: 3, yRadius: 3)
                rounded.fill()
            } else {
                bgColor.setFill()
                rect.fill()
            }

            // Draw separator (skip if either adjacent tab is selected)
            if i > 0, !tab.isSelected, !tabs[i - 1].isSelected {
                NSColor.separatorColor.setStroke()
                let sep = NSBezierPath()
                sep.move(to: NSPoint(x: rect.minX, y: 4))
                sep.line(to: NSPoint(x: rect.minX, y: tabHeight - 4))
                sep.lineWidth = 1
                sep.stroke()
            }

            // Draw title
            let baseName =
                tab.name.isEmpty ? "Tab \(i + 1)" : (tab.name as NSString).lastPathComponent
            let title = "\(i + 1). \(baseName)"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 14, weight: .regular),
                .foregroundColor: fgColor,
            ]
            let size = title.size(withAttributes: attrs)
            let textRect = CGRect(
                x: rect.midX - size.width / 2,
                y: rect.midY - size.height / 2,
                width: size.width,
                height: size.height
            )
            let clipped = textRect.intersection(rect.insetBy(dx: 8, dy: 0))
            title.draw(in: clipped, withAttributes: attrs)
        }

        // Bottom separator line
        NSColor.separatorColor.setStroke()
        let bottom = NSBezierPath()
        bottom.move(to: NSPoint(x: 0, y: 0))
        bottom.line(to: NSPoint(x: bounds.width, y: 0))
        bottom.lineWidth = 1
        bottom.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        let tabWidth = min(bounds.width / CGFloat(tabs.count), maxTabWidth)
        let index = Int(loc.x / tabWidth)
        if index >= 0, index < tabs.count {
            onSelectTab?(tabs[index].handle)
        }
    }
}
