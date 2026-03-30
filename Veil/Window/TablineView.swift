import AppKit

class TablineView: NSView {

    struct Tab {
        var handle: Int
        var name: String
        var isSelected: Bool
    }

    private(set) var tabs: [Tab] = []
    var onSelectTab: ((Int) -> Void)?

    private let tabHeight: CGFloat = 28

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
        let newHeight: CGFloat = tabs.count > 1 ? tabHeight : 0
        if heightConstraint.constant != newHeight {
            heightConstraint.constant = newHeight
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard tabs.count > 1 else { return }

        let bg = NSColor.windowBackgroundColor
        bg.setFill()
        dirtyRect.fill()

        let tabWidth = bounds.width / CGFloat(tabs.count)

        for (i, tab) in tabs.enumerated() {
            let rect = CGRect(x: CGFloat(i) * tabWidth, y: 0, width: tabWidth, height: tabHeight)

            if tab.isSelected {
                NSColor.controlAccentColor.withAlphaComponent(0.2).setFill()
            } else {
                NSColor.controlBackgroundColor.setFill()
            }
            rect.fill()

            // Draw separator
            if i > 0 {
                NSColor.separatorColor.setStroke()
                let sep = NSBezierPath()
                sep.move(to: NSPoint(x: rect.minX, y: 4))
                sep.line(to: NSPoint(x: rect.minX, y: tabHeight - 4))
                sep.lineWidth = 1
                sep.stroke()
            }

            // Draw bottom border for selected tab
            if tab.isSelected {
                NSColor.controlAccentColor.setFill()
                NSRect(x: rect.minX, y: 0, width: rect.width, height: 2).fill()
            }

            // Draw title
            let title = tab.name.isEmpty ? "Tab \(i + 1)" : (tab.name as NSString).lastPathComponent
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: tab.isSelected ? .medium : .regular),
                .foregroundColor: NSColor.labelColor,
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
        guard tabs.count > 1 else { return }
        let loc = convert(event.locationInWindow, from: nil)
        let tabWidth = bounds.width / CGFloat(tabs.count)
        let index = Int(loc.x / tabWidth)
        if index >= 0, index < tabs.count {
            onSelectTab?(index)
        }
    }
}
