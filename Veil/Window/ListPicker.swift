import AppKit

@MainActor
final class ListPicker {
    private static weak var activePanel: ListPickerPanel?

    /// Shows a floating picker panel for choosing one item from a list.
    /// Returns the selected item via `completion`, or `nil` if cancelled.
    /// Only one picker can be active at a time; repeated calls are ignored.
    static func pick<Item>(
        title: String,
        items: [Item],
        titleFor: @escaping (Item) -> String,
        subtitleFor: ((Item) -> String)? = nil,
        in parentWindow: NSWindow?,
        completion: @escaping (Item?) -> Void
    ) {
        guard activePanel == nil else { return }

        let titles = items.map(titleFor)
        let subtitles = subtitleFor.map { items.map($0) }

        let panel = ListPickerPanel(
            panelTitle: title,
            titles: titles,
            subtitles: subtitles
        ) { index in
            activePanel = nil
            completion(index.map { items[$0] })
        }
        activePanel = panel

        // Match picker appearance to the parent window's neovim colorscheme
        // so it doesn't clash (e.g. light picker over dark editor).
        let bg = UserDefaults.standard.object(forKey: "VeilDefaultBg") as? Int
        let isDark = bg.map { luminance(of: $0) < 0.5 } ?? true
        panel.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)

        if let parentWindow {
            let parentFrame = parentWindow.frame
            let pickerSize = panel.frame.size
            let x = parentFrame.midX - pickerSize.width / 2
            let y = parentFrame.midY - pickerSize.height / 2
            panel.setFrameOrigin(NSPoint(x: x, y: y))
            parentWindow.addChildWindow(panel, ordered: .above)
        } else {
            panel.center()
        }
        panel.makeKeyAndOrderFront(nil)
    }

    private static func luminance(of rgb: Int) -> CGFloat {
        let r = CGFloat((rgb >> 16) & 0xFF) / 255.0
        let g = CGFloat((rgb >> 8) & 0xFF) / 255.0
        let b = CGFloat(rgb & 0xFF) / 255.0
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }
}

// MARK: - Picker Panel

private final class ListPickerPanel: NSPanel, NSTextFieldDelegate {
    private let allTitles: [String]
    private let allSubtitles: [String]?
    private var filteredIndices: [Int]
    private let onDone: (Int?) -> Void
    private var selectedIndex = 0
    private var itemViews: [ListPickerItemView] = []
    private let stackView = NSStackView()
    private let searchField = NSTextField()
    private let scrollView = NSScrollView()

    private let panelWidth: CGFloat = 280
    private let itemHeight: CGFloat = 32
    private let subtitleItemHeight: CGFloat = 44
    private let padding: CGFloat = 6
    private let searchFieldHeight: CGFloat = 28
    private let titleLabelHeight: CGFloat = 24

    /// Per-row height: rows with a non-empty subtitle get the taller height
    /// to fit title + subtitle stacked; others get the compact single-line
    /// height. Static because it's called during init before self is fully
    /// initialized, so it can't access instance properties directly.
    private static func heightForItem(
        at index: Int, subtitles: [String]?,
        itemHeight: CGFloat, subtitleItemHeight: CGFloat
    ) -> CGFloat {
        if let subtitles, !subtitles[index].isEmpty {
            return subtitleItemHeight
        }
        return itemHeight
    }

    init(
        panelTitle: String,
        titles: [String],
        subtitles: [String]?,
        onDone: @escaping (Int?) -> Void
    ) {
        self.allTitles = titles
        self.allSubtitles = subtitles
        self.filteredIndices = Array(titles.indices)
        self.onDone = onDone

        let ih = itemHeight
        let sih = subtitleItemHeight
        let listHeight = titles.indices.reduce(CGFloat(0)) {
            $0
                + Self.heightForItem(
                    at: $1, subtitles: subtitles, itemHeight: ih, subtitleItemHeight: sih)
        }
        let panelHeight = Self.calculateHeight(
            listHeight: listHeight,
            searchFieldHeight: searchFieldHeight, titleLabelHeight: titleLabelHeight,
            padding: padding
        )

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .modalPanel
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true

        let container = NSVisualEffectView(frame: .zero)
        container.material = .popover
        container.state = .active
        container.blendingMode = .behindWindow
        container.wantsLayer = true
        container.layer?.cornerRadius = 8
        container.layer?.masksToBounds = true
        contentView = container

        // Title label
        let titleLabel = NSTextField(labelWithString: panelTitle)
        titleLabel.font = .boldSystemFont(ofSize: 14)
        titleLabel.textColor = .labelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(titleLabel)

        // Search field
        searchField.placeholderString = "Filter…"
        searchField.font = .systemFont(ofSize: 13)
        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.textColor = .labelColor
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(searchField)

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(separator)

        // List area
        stackView.orientation = .vertical
        stackView.spacing = 0
        stackView.translatesAutoresizingMaskIntoConstraints = false

        scrollView.documentView = stackView
        scrollView.hasVerticalScroller = false
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: padding + 2),
            titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),

            searchField.topAnchor.constraint(
                equalTo: titleLabel.bottomAnchor, constant: padding),
            searchField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            searchField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            searchField.heightAnchor.constraint(equalToConstant: searchFieldHeight),

            separator.topAnchor.constraint(
                equalTo: searchField.bottomAnchor, constant: padding / 2),
            separator.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: padding / 2),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -padding),

            stackView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            stackView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
        ])

        rebuildList()
        makeFirstResponder(searchField)
    }

    // MARK: - Keyboard

    override func cancelOperation(_ sender: Any?) {
        dismiss(nil)
    }

    override var canBecomeKey: Bool { true }

    // MARK: - NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        applyFilter(searchField.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector)
        -> Bool
    {
        // Vim-style Ctrl+N/P and Ctrl+J/K for list navigation. These keys
        // get intercepted by the text input system before keyDown, so we
        // catch them here via the original event instead.
        if let event = NSApp.currentEvent, event.modifierFlags.contains(.control) {
            let chars = event.charactersIgnoringModifiers ?? ""
            if chars == "n" || chars == "j" {
                moveSelection(by: 1)
                return true
            } else if chars == "p" || chars == "k" {
                moveSelection(by: -1)
                return true
            }
        }

        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: 1)
            return true
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -1)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            confirmSelection()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            dismiss(nil)
            return true
        case #selector(NSResponder.insertTab(_:)):
            moveSelection(by: 1)
            return true
        case #selector(NSResponder.insertBacktab(_:)):
            moveSelection(by: -1)
            return true
        default:
            return false
        }
    }

    // MARK: - Filtering

    private func applyFilter(_ query: String) {
        if query.isEmpty {
            filteredIndices = Array(allTitles.indices)
        } else {
            filteredIndices = allTitles.indices.filter { i in
                let matchesTitle = fuzzyMatch(query: query, target: allTitles[i])
                let matchesSubtitle =
                    allSubtitles.map { fuzzyMatch(query: query, target: $0[i]) } ?? false
                return matchesTitle || matchesSubtitle
            }
        }
        selectedIndex = 0
        rebuildList()
        resizeToFit()
    }

    private func fuzzyMatch(query: String, target: String) -> Bool {
        var qi = query.lowercased().startIndex
        let q = query.lowercased()
        let t = target.lowercased()

        for char in t {
            guard qi < q.endIndex else { return true }
            if char == q[qi] {
                qi = q.index(after: qi)
            }
        }
        return qi == q.endIndex
    }

    // MARK: - List Management

    private func rebuildList() {
        for view in stackView.arrangedSubviews { view.removeFromSuperview() }
        itemViews.removeAll()

        for (position, originalIndex) in filteredIndices.enumerated() {
            let subtitle = allSubtitles?[originalIndex]
            let item = ListPickerItemView(
                title: allTitles[originalIndex],
                subtitle: subtitle,
                isSelected: position == selectedIndex
            )
            item.translatesAutoresizingMaskIntoConstraints = false
            item.heightAnchor.constraint(
                equalToConstant: Self.heightForItem(
                    at: originalIndex, subtitles: allSubtitles,
                    itemHeight: itemHeight, subtitleItemHeight: subtitleItemHeight)
            ).isActive = true
            item.widthAnchor.constraint(equalToConstant: panelWidth).isActive = true
            item.onClicked = { [weak self] in
                self?.selectedIndex = position
                self?.confirmSelection()
            }
            stackView.addArrangedSubview(item)
            itemViews.append(item)
        }
    }

    private func resizeToFit() {
        let listHeight = filteredIndices.reduce(CGFloat(0)) {
            $0
                + Self.heightForItem(
                    at: $1, subtitles: allSubtitles,
                    itemHeight: itemHeight, subtitleItemHeight: subtitleItemHeight)
        }
        let newHeight = Self.calculateHeight(
            listHeight: listHeight,
            searchFieldHeight: searchFieldHeight, titleLabelHeight: titleLabelHeight,
            padding: padding
        )
        var frame = self.frame
        let delta = newHeight - frame.height
        frame.origin.y -= delta
        frame.size.height = newHeight
        setFrame(frame, display: true, animate: false)
    }

    private static func calculateHeight(
        listHeight: CGFloat,
        searchFieldHeight: CGFloat, titleLabelHeight: CGFloat,
        padding: CGFloat
    ) -> CGFloat {
        let effectiveListHeight = max(listHeight, 32)
        return titleLabelHeight + searchFieldHeight + padding * 4 + effectiveListHeight
    }

    // MARK: - Selection

    private func moveSelection(by delta: Int) {
        guard !filteredIndices.isEmpty else { return }
        let newIndex = (selectedIndex + delta + filteredIndices.count) % filteredIndices.count
        updateSelection(newIndex)
    }

    private func updateSelection(_ index: Int) {
        if selectedIndex < itemViews.count { itemViews[selectedIndex].isSelected = false }
        selectedIndex = index
        if selectedIndex < itemViews.count { itemViews[selectedIndex].isSelected = true }
    }

    private func confirmSelection() {
        guard !filteredIndices.isEmpty, selectedIndex < filteredIndices.count else { return }
        dismiss(filteredIndices[selectedIndex])
    }

    private func dismiss(_ index: Int?) {
        parent?.removeChildWindow(self)
        orderOut(nil)
        onDone(index)
    }
}

// MARK: - Item View

private final class ListPickerItemView: NSView {
    var isSelected: Bool = false {
        didSet { needsDisplay = true }
    }
    var onClicked: (() -> Void)?

    private let titleLabel: NSTextField
    private let subtitleLabel: NSTextField?

    init(title: String, subtitle: String?, isSelected: Bool) {
        self.titleLabel = NSTextField(labelWithString: title)
        let effectiveSubtitle = subtitle?.isEmpty == false ? subtitle : nil
        self.subtitleLabel = effectiveSubtitle.map { NSTextField(labelWithString: $0) }
        self.isSelected = isSelected
        super.init(frame: .zero)

        titleLabel.font = .systemFont(ofSize: 13, weight: .regular)
        titleLabel.textColor = .labelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        if let subtitleLabel {
            subtitleLabel.font = .systemFont(ofSize: 11)
            subtitleLabel.textColor = .secondaryLabelColor
            subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
            addSubview(subtitleLabel)

            // Stack title + subtitle vertically, centered as a group
            let spacing: CGFloat = 1
            NSLayoutConstraint.activate([
                titleLabel.bottomAnchor.constraint(
                    equalTo: centerYAnchor, constant: -spacing / 2),
                titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
                titleLabel.trailingAnchor.constraint(
                    lessThanOrEqualTo: trailingAnchor, constant: -16),

                subtitleLabel.topAnchor.constraint(
                    equalTo: centerYAnchor, constant: spacing / 2),
                subtitleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
                subtitleLabel.trailingAnchor.constraint(
                    lessThanOrEqualTo: trailingAnchor, constant: -16),
            ])
        } else {
            NSLayoutConstraint.activate([
                titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
                titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
                titleLabel.trailingAnchor.constraint(
                    lessThanOrEqualTo: trailingAnchor, constant: -16),
            ])
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        if isSelected {
            NSColor.controlAccentColor.withAlphaComponent(0.3).setFill()
            bounds.fill()
        }
    }

    override func mouseDown(with event: NSEvent) {
        onClicked?()
    }
}
