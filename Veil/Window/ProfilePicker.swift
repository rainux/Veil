import AppKit

@MainActor
final class ProfilePicker {
    private static weak var activePanel: ProfilePickerPanel?

    /// Shows a floating picker panel anchored to the top of the given window.
    /// Calls `completion` with the chosen profile, or does nothing if cancelled.
    /// If only one (or zero) profiles are available, completes immediately with the default.
    /// Ignores repeated calls while already showing.
    static func pick(in parentWindow: NSWindow?, completion: @escaping (Profile) -> Void) {
        guard activePanel == nil else { return }

        let profiles = Profile.availableProfiles()
        guard profiles.count > 1 else {
            completion(.default)
            return
        }

        let picker = ProfilePickerPanel(profiles: profiles) { profile in
            activePanel = nil
            if let profile { completion(profile) }
        }
        activePanel = picker

        // Match picker appearance to the parent window's neovim colorscheme
        // so it doesn't clash (e.g. light picker over dark editor).
        let bg = UserDefaults.standard.object(forKey: "VeilDefaultBg") as? Int
        let isDark = bg.map { Self.luminance(of: $0) < 0.5 } ?? true
        picker.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)

        if let parentWindow {
            let parentFrame = parentWindow.frame
            let pickerSize = picker.frame.size
            let x = parentFrame.midX - pickerSize.width / 2
            let y = parentFrame.midY - pickerSize.height / 2
            picker.setFrameOrigin(NSPoint(x: x, y: y))
            parentWindow.addChildWindow(picker, ordered: .above)
        } else {
            picker.center()
        }
        picker.makeKeyAndOrderFront(nil)
    }

    private static func luminance(of rgb: Int) -> CGFloat {
        let r = CGFloat((rgb >> 16) & 0xFF) / 255.0
        let g = CGFloat((rgb >> 8) & 0xFF) / 255.0
        let b = CGFloat(rgb & 0xFF) / 255.0
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }
}

// MARK: - Picker Panel

private final class ProfilePickerPanel: NSPanel, NSTextFieldDelegate {
    private let allProfiles: [Profile]
    private var filteredProfiles: [Profile]
    private let onDone: (Profile?) -> Void
    private var selectedIndex = 0
    private var itemViews: [ProfileItemView] = []
    private let stackView = NSStackView()
    private let searchField = NSTextField()
    private let scrollView = NSScrollView()

    private let panelWidth: CGFloat = 280
    private let itemHeight: CGFloat = 32
    private let padding: CGFloat = 6
    private let searchFieldHeight: CGFloat = 28

    init(profiles: [Profile], onDone: @escaping (Profile?) -> Void) {
        self.allProfiles = profiles
        self.filteredProfiles = profiles
        self.onDone = onDone

        let panelHeight = Self.calculateHeight(
            itemCount: profiles.count, itemHeight: itemHeight,
            searchFieldHeight: searchFieldHeight, padding: padding
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
            searchField.topAnchor.constraint(equalTo: container.topAnchor, constant: padding),
            searchField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            searchField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            searchField.heightAnchor.constraint(equalToConstant: searchFieldHeight),

            separator.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: padding / 2),
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

    override func keyDown(with event: NSEvent) {
        let isCtrl = event.modifierFlags.contains(.control)
        let chars = event.charactersIgnoringModifiers ?? ""

        if isCtrl && chars == "n" {
            moveSelection(by: 1)
        } else if isCtrl && chars == "p" {
            moveSelection(by: -1)
        } else {
            super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        dismiss(nil)
    }

    override var canBecomeKey: Bool { true }

    // MARK: - NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        applyFilter(searchField.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
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
            filteredProfiles = allProfiles
        } else {
            filteredProfiles = allProfiles.filter { fuzzyMatch(query: query, target: $0.displayName) }
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

        for (index, profile) in filteredProfiles.enumerated() {
            let item = ProfileItemView(title: profile.displayName, isSelected: index == selectedIndex)
            item.translatesAutoresizingMaskIntoConstraints = false
            item.heightAnchor.constraint(equalToConstant: itemHeight).isActive = true
            item.widthAnchor.constraint(equalToConstant: panelWidth).isActive = true
            item.onClicked = { [weak self] in
                self?.selectedIndex = index
                self?.confirmSelection()
            }
            stackView.addArrangedSubview(item)
            itemViews.append(item)
        }
    }

    private func resizeToFit() {
        let newHeight = Self.calculateHeight(
            itemCount: filteredProfiles.count, itemHeight: itemHeight,
            searchFieldHeight: searchFieldHeight, padding: padding
        )
        var frame = self.frame
        let delta = newHeight - frame.height
        frame.origin.y -= delta
        frame.size.height = newHeight
        setFrame(frame, display: true, animate: false)
    }

    private static func calculateHeight(itemCount: Int, itemHeight: CGFloat,
                                         searchFieldHeight: CGFloat, padding: CGFloat) -> CGFloat {
        let listHeight = CGFloat(max(itemCount, 1)) * itemHeight
        return searchFieldHeight + padding * 3 + listHeight
    }

    // MARK: - Selection

    private func moveSelection(by delta: Int) {
        guard !filteredProfiles.isEmpty else { return }
        let newIndex = (selectedIndex + delta + filteredProfiles.count) % filteredProfiles.count
        updateSelection(newIndex)
    }

    private func updateSelection(_ index: Int) {
        if selectedIndex < itemViews.count { itemViews[selectedIndex].isSelected = false }
        selectedIndex = index
        if selectedIndex < itemViews.count { itemViews[selectedIndex].isSelected = true }
    }

    private func confirmSelection() {
        guard !filteredProfiles.isEmpty, selectedIndex < filteredProfiles.count else { return }
        dismiss(filteredProfiles[selectedIndex])
    }

    private func dismiss(_ profile: Profile?) {
        parent?.removeChildWindow(self)
        orderOut(nil)
        onDone(profile)
    }
}

// MARK: - Item View

private final class ProfileItemView: NSView {
    var isSelected: Bool = false {
        didSet { needsDisplay = true }
    }
    var onClicked: (() -> Void)?

    private let label: NSTextField

    init(title: String, isSelected: Bool) {
        self.label = NSTextField(labelWithString: title)
        self.isSelected = isSelected
        super.init(frame: .zero)

        label.font = .systemFont(ofSize: 13, weight: .regular)
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
        ])
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
